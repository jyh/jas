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
    // A non-finite hue is sanitised to 0 in BOTH ports before the sector index
    // is taken. Here `as u32` would give 0 and then carry NaN into two of the
    // three components; in Swift `Int(floor(h / 60.0))` is a precondition
    // failure. Neither is a colour, so the ports agree on 0 instead. Risk R9,
    // transcripts/CORPUS_CENSUS.md §7. Swift twin: Geometry/Element.swift
    // hsbToRgbComponents.
    let h = if h.is_finite() {
        ((h % 360.0) + 360.0) % 360.0 // normalize hue
    } else {
        0.0
    };
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

/// SVG-style fill rule. Determines how a multi-subpath shape is filled.
/// Defaults to NonZero (the SVG default).
///
/// This is the **document-side** half of the carried-rule law
/// (transcripts/BOOLEAN.md, "Fill rule: the polygon set carries it"):
/// what the artist or the imported file declared. The algorithm-side
/// half is [`crate::algorithms::boolean::PolyFillRule`], and the `From`
/// impls below are the only bridge between them — a boolean operand
/// must carry this value across, never assume one. Boolean *results*
/// are stamped with [`crate::algorithms::boolean::RESULT_FILL_RULE`],
/// which is `EvenOdd`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, serde::Serialize, serde::Deserialize)]
pub enum FillRule {
    #[default]
    #[serde(rename = "nonzero")]
    NonZero,
    #[serde(rename = "evenodd")]
    EvenOdd,
}

impl From<FillRule> for crate::algorithms::boolean::PolyFillRule {
    fn from(r: FillRule) -> Self {
        use crate::algorithms::boolean::PolyFillRule as P;
        match r {
            FillRule::NonZero => P::NonZero,
            FillRule::EvenOdd => P::EvenOdd,
        }
    }
}

impl From<crate::algorithms::boolean::PolyFillRule> for FillRule {
    fn from(r: crate::algorithms::boolean::PolyFillRule) -> Self {
        use crate::algorithms::boolean::PolyFillRule as P;
        match r {
            P::NonZero => FillRule::NonZero,
            P::EvenOdd => FillRule::EvenOdd,
        }
    }
}

fn fill_rule_is_default(r: &FillRule) -> bool { matches!(r, FillRule::NonZero) }

// ---------------------------------------------------------------------------
// Bounding box
// ---------------------------------------------------------------------------

/// Axis-aligned bounding box (x, y, width, height).
pub type Bounds = (f64, f64, f64, f64);

/// Expand bounding box (x, y, w, h) by the ink the stroke actually puts
/// OUTSIDE the path, which depends on `stroke.align`.
///
/// RULED 2026-08-21: Center inflates by w/2 on each side, Inside not at all,
/// Outside by the full w. Twin: JasSwift's `inflateBounds`.
///
/// This used to inflate by w/2 unconditionally -- exactly right for Center and
/// wrong for the other two by w/2 per side, an error that SCALES with the
/// stroke (20pt on a 40pt stroke). Both ports were wrong in the same way, so
/// the cross-language equivalence law was blind to it by construction: a shared
/// defect agrees with itself.
///
/// NO CLOSEDNESS BRANCH. `workspace/actions.yaml` says "Inside and outside
/// behave as center on open paths", and no renderer implements that sentence:
/// `canvas/render.rs::stroke_aligned` draws Inside by clipping to the path's
/// fill area at 2x width, and canvas implicitly closes an open path for
/// clipping, so an open path's ink is clipped exactly as a closed one's is.
/// Bounds are a claim about where the ink IS, so they follow the ink. That
/// stale sentence needs a ruling of its own; it is not honoured by guessing
/// here.
fn inflate_bounds(bbox: Bounds, stroke: Option<&Stroke>) -> Bounds {
    match stroke {
        None => bbox,
        Some(s) => {
            let outward = match s.align {
                StrokeAlign::Center => s.width / 2.0,
                StrokeAlign::Inside => 0.0,
                StrokeAlign::Outside => s.width,
            };
            (
                bbox.0 - outward,
                bbox.1 - outward,
                bbox.2 + 2.0 * outward,
                bbox.3 + 2.0 * outward,
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
    /// User-visible name. None means the element is unnamed and the
    /// UI shows a `<Type>` fallback (per LYR-022). Round-trips through
    /// SVG as a `<title>` child element. Layers retain their own
    /// LayerElem.name for back-compat during the rollout; the
    /// Element::display_name() helper prefers this field when set.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// Stable, opaque element identity. Additive: `None` means the
    /// element has no id yet, so every existing document remains valid.
    /// Where the tree-path encodes *where* an element sits, the id names
    /// *which* element it is, surviving reorder and edit. It is the
    /// foundation for the live relationship graph, cross-tree
    /// references, versioning, and collaboration (see VISION.md §6.2).
    /// A plain string so it serializes and compares identically across
    /// all five implementations. Round-trips through test_json (emitted
    /// only when set, so id-less elements stay byte-identical) and,
    /// in a later increment, the SVG `id` attribute.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
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
            name: None,
            id: None,
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
    /// Fill rule for multi-subpath paths. Boolean operation outputs use
    /// EvenOdd; pen-drawn paths use NonZero (the default). Stored on
    /// the element so serialization round-trips it.
    #[serde(default, skip_serializing_if = "fill_rule_is_default")]
    pub fill_rule: FillRule,
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

    /// Returns `true` when every tspan can be rendered by the
    /// flat / paragraph-aware fast path:
    ///
    /// - Empty paragraph wrappers (`jas_role == "paragraph"`) are
    ///   metadata only — `build_segments_from_text` reads them; their
    ///   character-level fields are ignored at render time, so an
    ///   empty wrapper never forces the segmented path.
    /// - Body tspans (no `jas_role`) must carry no character-level
    ///   overrides; otherwise the per-tspan font / decoration / dx /
    ///   transform must go through `draw_segmented_text`.
    ///
    /// Without this, the moment the Paragraph panel inserts an empty
    /// wrapper before existing flat content, the renderer flips to
    /// `draw_segmented_text` (which is single-line) and the paragraph
    /// collapses visually.
    pub fn render_is_flat(&self) -> bool {
        self.tspans.iter().all(|t| {
            if t.jas_role.as_deref() == Some("paragraph") {
                t.content.is_empty()
            } else {
                t.has_no_overrides()
            }
        })
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

/// Build a new Text element with empty content at (x, y) using the house
/// defaults. Used when the user clicks the type tool on empty canvas.
///
/// Lives here rather than in `tools::text_edit` because it is a pure
/// constructor over `TextElem` — defined in this module — with no UI
/// dependency, while `tools` is gated behind `feature = "web"`. That gating by
/// association is what stopped `geometry::svg`'s own round-trip tests from
/// building natively; see `scripts/check_native_core_tests.py`.
/// `tools::text_edit` re-exports it, so existing call sites are unchanged.
pub fn empty_text_elem(x: f64, y: f64, width: f64, height: f64) -> TextElem {
    TextElem::from_string(
        x,
        y,
        "",
        "sans-serif",
        16.0,
        "normal",
        "normal",
        "none",
        width,
        height,
        Some(Fill::new(Color::BLACK)),
        None,
        CommonProps::default(),
    )
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

impl LayerElem {
    /// Layer's user-visible name. Backed by `common.name`; returns "" when
    /// the layer is unnamed (callers like the layers panel substitute
    /// "Layer N" themselves).
    pub fn name(&self) -> &str {
        self.common.name.as_deref().unwrap_or("")
    }

    /// Convenience setter: routes through `common.name`. Empty string
    /// is normalized to `None` so an unnamed layer round-trips as null
    /// rather than as the empty string.
    pub fn set_name(&mut self, name: impl Into<String>) {
        let s = name.into();
        self.common.name = if s.is_empty() { None } else { Some(s) };
    }
}

// ---------------------------------------------------------------------------
// Element accessors
// ---------------------------------------------------------------------------

impl Element {
    pub fn common(&self) -> &CommonProps {
        match self {
            Element::Line(e) => &e.common,
            Element::Rect(e) => &e.common,
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
                    // CHARWIDTH (2026-07-29): ONE arm, both builds. This used to
                    // be two — the `web` arm called the shared measurer, and the
                    // non-`web` arm reimplemented the width law wrongly TWICE
                    // over: it used APPROX_CHAR_WIDTH_FACTOR (0.6) where the
                    // shared measurer's host fallback is 0.55, so every native
                    // text bound came out ~9% too wide; and it counted `l.len()`,
                    // i.e. UTF-8 BYTES, where the measurer counts chars, so any
                    // non-ASCII content inflated the box further.
                    //
                    // `point_text_bounds_width_matches_real_measurer_not_stub`
                    // exists to forbid exactly the 0.6 stub and had never been
                    // able to run where the stub lived — `tools` is web-gated, so
                    // the whole native test target failed to build until today.
                    // The divergence survived because the only platform that
                    // could see it could not compile the test that watches it.
                    let max_width = {
                        let font = crate::text_measure::font_string(
                            &e.font_style, &e.font_weight, e.font_size, &e.font_family);
                        let measure = crate::text_measure::make_measurer(&font, e.font_size);
                        lines.iter().map(|l| measure(l)).fold(0.0_f64, f64::max)
                    };
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

/// Compute the candidate (x, y) extrema points for an SVG arc. The
/// arc is parameterized as in SVG 1.1 §F.6: endpoint to endpoint with
/// radii (rx, ry), x-axis rotation (degrees), and the two flags. The
/// returned list always includes the two endpoints; it additionally
/// includes any of the four cardinal-direction extrema of the rotated
/// ellipse that fall within the arc's actual sweep range.
///
/// Used by path bounds to fix the well-known "ArcTo bbox skips the
/// peak" gap (see project_arc_extrema_gap memory note). Degenerate
/// arcs (zero radius) collapse to the endpoint pair.
fn arc_extrema_points(
    x0: f64, y0: f64,
    rx: f64, ry: f64, x_rotation_deg: f64,
    large_arc: bool, sweep: bool,
    x: f64, y: f64,
) -> Vec<(f64, f64)> {
    if rx.abs() < 1e-12 || ry.abs() < 1e-12 {
        return vec![(x0, y0), (x, y)];
    }
    let two_pi = 2.0 * std::f64::consts::PI;
    let phi = x_rotation_deg.to_radians();
    let cos_phi = phi.cos();
    let sin_phi = phi.sin();

    // SVG endpoint-to-center conversion, per F.6.5.
    let dx = (x0 - x) / 2.0;
    let dy = (y0 - y) / 2.0;
    let x1p =  cos_phi * dx + sin_phi * dy;
    let y1p = -sin_phi * dx + cos_phi * dy;
    let mut rx_eff = rx.abs();
    let mut ry_eff = ry.abs();
    let lambda = (x1p * x1p) / (rx_eff * rx_eff) + (y1p * y1p) / (ry_eff * ry_eff);
    if lambda > 1.0 {
        let s = lambda.sqrt();
        rx_eff *= s;
        ry_eff *= s;
    }
    let sign = if large_arc == sweep { -1.0 } else { 1.0 };
    let num = (rx_eff * rx_eff * ry_eff * ry_eff
        - rx_eff * rx_eff * y1p * y1p
        - ry_eff * ry_eff * x1p * x1p).max(0.0);
    let den = rx_eff * rx_eff * y1p * y1p + ry_eff * ry_eff * x1p * x1p;
    let factor = if den < 1e-12 { 0.0 } else { sign * (num / den).sqrt() };
    let cxp =  factor * (rx_eff * y1p) / ry_eff;
    let cyp = -factor * (ry_eff * x1p) / rx_eff;
    let cx_arc = cos_phi * cxp - sin_phi * cyp + (x0 + x) / 2.0;
    let cy_arc = sin_phi * cxp + cos_phi * cyp + (y0 + y) / 2.0;

    let theta1 = ((y1p - cyp) / ry_eff).atan2((x1p - cxp) / rx_eff);
    let theta2 = ((-y1p - cyp) / ry_eff).atan2((-x1p - cxp) / rx_eff);
    let mut delta = theta2 - theta1;
    if !sweep && delta > 0.0 { delta -= two_pi; }
    else if sweep && delta < 0.0 { delta += two_pi; }

    // x(t) = cx_arc + rx*cos(phi)*cos(t) - ry*sin(phi)*sin(t)
    // dx/dt = 0  →  tan(t) = -ry*sin(phi) / (rx*cos(phi))
    // y(t) = cy_arc + rx*sin(phi)*cos(t) + ry*cos(phi)*sin(t)
    // dy/dt = 0  →  tan(t) =  ry*cos(phi) / (rx*sin(phi))
    let tx = (-ry_eff * sin_phi).atan2(rx_eff * cos_phi);
    let ty = (ry_eff * cos_phi).atan2(rx_eff * sin_phi);
    let candidates = [tx, tx + std::f64::consts::PI, ty, ty + std::f64::consts::PI];

    let in_sweep = |t: f64| -> bool {
        let mut dt = t - theta1;
        if delta >= 0.0 {
            while dt < 0.0 { dt += two_pi; }
            while dt > two_pi { dt -= two_pi; }
            dt <= delta + 1e-9
        } else {
            while dt > 0.0 { dt -= two_pi; }
            while dt < -two_pi { dt += two_pi; }
            dt >= delta - 1e-9
        }
    };

    let mut points = vec![(x0, y0), (x, y)];
    for &t in &candidates {
        if in_sweep(t) {
            let px = cx_arc + rx_eff * cos_phi * t.cos() - ry_eff * sin_phi * t.sin();
            let py = cy_arc + rx_eff * sin_phi * t.cos() + ry_eff * cos_phi * t.sin();
            points.push((px, py));
        }
    }
    points
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
            PathCommand::ArcTo { rx, ry, x_rotation, large_arc, sweep, x, y } => {
                for (px, py) in arc_extrema_points(
                    cx, cy, *rx, *ry, *x_rotation, *large_arc, *sweep, *x, *y,
                ) {
                    xs.push(px);
                    ys.push(py);
                }
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

/// Axis-aligned box of `b`'s four corners mapped through `t` — the repo's one
/// meaning of "a bbox through a transform", shared with the Python reference's
/// `_aabb_through` and the Properties-panel evaluated-bbox family.
///
/// ⚖️ This is what carries A6 §3.3's ruled contract (the helm's design word,
/// 2026-08-31): the reveal law's precomputed bbox is the axis-aligned bounds
/// OF the transformed mask subtree — `bounds(mask_xf · subtree)`, never the
/// transform of its bounds as a region, which a rotation makes inexpressible
/// in an axis-aligned `Rect`. Applied to the subtree's own bounds this is
/// exact for every axis-preserving transform and for any subtree whose
/// geometry reaches its bbox corners (every rect mask); for a rotated subtree
/// that does not, it is the box of the transformed BOUNDS — a superset of the
/// transformed geometry's box, the same over-approximation the evaluated-bbox
/// family already makes. Both mask paths call this one function, so they
/// cannot disagree with each other.
pub fn aabb_through(b: Bounds, t: &Transform) -> Bounds {
    let (bx, by, bw, bh) = b;
    let mut min_x = f64::INFINITY;
    let mut min_y = f64::INFINITY;
    let mut max_x = f64::NEG_INFINITY;
    let mut max_y = f64::NEG_INFINITY;
    for (px, py) in [(bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh)] {
        let (x, y) = t.apply_point(px, py);
        min_x = min_x.min(x);
        min_y = min_y.min(y);
        max_x = max_x.max(x);
        max_y = max_y.max(y);
    }
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

/// Geometric bounds that RESOLVE the three live kinds whose geometry lives
/// behind an id (`Reference` / `Recorded` / `Generated`), returning `None` for
/// an element that occupies no canvas at all.
///
/// `Element::geometric_bounds` and `Element::bounds` are deliberately left
/// resolver-less and both keep answering `(0,0,0,0)` for those kinds — the same
/// two-form split as `hit_test`'s plain and `_with` verbs, for the same reason:
/// with no document behind it, there is no fact about where a target id is.
/// Readers that HAVE a resolver use this; readers that do not keep the answer
/// they had.
///
/// ## Why `Option`, and why it is the whole point
///
/// A dangling instance draws nothing, so it must contribute NOTHING to a
/// union — not a zero-sized box at the origin. `geometric_children_bounds`
/// unions its children unconditionally, so a group holding one instance
/// reported a box STRETCHED BACK TO (0,0): measured `(0,0,110,110)` for a group
/// whose true extent was `(5,7,105,103)`. The empty box was not merely absent,
/// it was a phantom point at the origin that the union swallowed.
///
/// Degenerate boxes from every OTHER kind still contribute exactly as before
/// (a zero-width rect is a real point on the canvas, and this is not the place
/// to relitigate that).
pub fn resolved_geometric_bounds(
    elem: &Element,
    resolver: &dyn super::live::ElementResolver,
) -> Option<Bounds> {
    resolved_bounds_with(elem, resolver, Element::geometric_bounds)
}

/// [`resolved_geometric_bounds`] with the leaf measurement chosen by the
/// caller: pass [`Element::geometric_bounds`] for the stroke-exclusive box or
/// [`Element::bounds`] for the stroke-inflated (preview) one.
///
/// The parameter exists because Align reads both, under its Use Preview Bounds
/// flag. Hard-coding the geometric leaf here would have silently dropped stroke
/// inflation from every leaf inside a GROUP the moment align started resolving
/// — fixing an instance's box by breaking every stroked sibling's.
///
/// **A resolver-backed kind answers with its resolved rings under EITHER leaf
/// choice**, because evaluated rings carry no stroke. So an instance's own
/// stroke inflation is still missing in preview mode; it would need the
/// resolved TARGET's stroke, which is a different piece of work. That is a
/// bounded, stated shortfall — and strictly better than the zero box it
/// replaces, which was wrong in both modes.
pub fn resolved_bounds_with(
    elem: &Element,
    resolver: &dyn super::live::ElementResolver,
    leaf: fn(&Element) -> Bounds,
) -> Option<Bounds> {
    if let Some(rings) = super::live::resolved_rings(elem, resolver) {
        // A resolver-backed kind: its box is its resolved rings', and nothing
        // at all when those rings are empty.
        return super::live::rings_bbox(&rings);
    }
    match elem {
        Element::Group(g) => resolved_children_bounds(&g.children, resolver, leaf),
        Element::Layer(l) => resolved_children_bounds(&l.children, resolver, leaf),
        _ => Some(leaf(elem)),
    }
}

/// Union of the children's resolved bounds, skipping the ones that occupy
/// nothing. `None` when no child occupies anything (including the
/// empty-children case, which `geometric_children_bounds` reports as the
/// degenerate box at the origin).
fn resolved_children_bounds(
    children: &[Rc<Element>],
    resolver: &dyn super::live::ElementResolver,
    leaf: fn(&Element) -> Bounds,
) -> Option<Bounds> {
    let mut acc: Option<(f64, f64, f64, f64)> = None;
    for c in children {
        let Some((x, y, w, h)) = resolved_bounds_with(c, resolver, leaf) else {
            continue;
        };
        acc = Some(match acc {
            None => (x, y, x + w, y + h),
            Some((ax, ay, bx, by)) => {
                (ax.min(x), ay.min(y), bx.max(x + w), by.max(y + h))
            }
        });
    }
    acc.map(|(ax, ay, bx, by)| (ax, ay, bx - ax, by - ay))
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
        Element::Rect(_) | Element::Ellipse(_) => 4,
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
        Element::Ellipse(e) => vec![
            (e.cx, e.cy - e.ry),
            (e.cx + e.rx, e.cy),
            (e.cx, e.cy + e.ry),
            (e.cx - e.rx, e.cy),
        ],
        Element::Polygon(e) => e.points.clone(),
        Element::Path(e) => path_anchor_points(&e.d),
        Element::TextPath(e) => path_anchor_points(&e.d),
        _ => bbox_corners(elem.bounds()),
    }
}

fn bbox_corners((bx, by, bw, bh): Bounds) -> Vec<(f64, f64)> {
    vec![(bx, by), (bx + bw, by), (bx + bw, by + bh), (bx, by + bh)]
}

/// [`control_points`] for an element that may measure something ELSEWHERE in
/// the document — a symbol instance and its recorded / generated siblings.
///
/// The kinds that carry their own coordinates answer identically; the
/// resolver-backed ones fall to the bbox-corner branch, and THAT is where the
/// two differ. `bounds()` has no resolver, so it answers a zero box at the
/// ORIGIN for them, and the four "corners" collapse onto (0,0): a selected
/// instance drew its box correctly (the box resolves) with its four resize
/// handles stacked in the corner of the document. Spelled as a second NAME
/// rather than a defaulted argument so no caller can get the narrow answer by
/// omission.
pub fn control_points_with(
    elem: &Element,
    resolver: &dyn super::live::ElementResolver,
) -> Vec<(f64, f64)> {
    match elem {
        Element::Live(_) => match resolved_bounds_with(elem, resolver, Element::bounds) {
            // Resolved to nothing (dangling / cyclic): no handles at all is
            // the honest answer — the origin would be a claim about where it
            // is. Mirrors `resolved_bounds_with` returning None.
            None => Vec::new(),
            Some(b) => bbox_corners(b),
        },
        _ => control_points(elem),
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
    let mut sx = 0.0_f64; // current subpath start (reset on each MoveTo)
    let mut sy = 0.0_f64;
    let steps = FLATTEN_STEPS;
    for cmd in d {
        match cmd {
            PathCommand::MoveTo { x, y } => {
                pts.push((*x, *y));
                cx = *x;
                cy = *y;
                sx = *x;
                sy = *y;
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
                // Close to the CURRENT subpath start, not the whole-path first
                // point — matters once there are >=2 subpaths (compound shapes,
                // glyphs-with-holes, boolean outputs). Matches OCaml/Swift.
                if !pts.is_empty() {
                    pts.push((sx, sy));
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

/// The rounded rect's outline, split into ONE POINT RUN PER CORNER, in the
/// same order as a Rect's four control points: 0 = top-left, 1 = top-right,
/// 2 = bottom-right, 3 = bottom-left. Concatenating the four runs in that
/// order yields the closed outline.
///
/// A SQUARE rect (`rx <= 0 && ry <= 0`, or a clamp that lands there) gives
/// four single-point runs — exactly the four corners, so the concatenation is
/// byte-identical to what the Rect -> Polygon promotion has always emitted.
/// A ROUNDED rect gives four equal-length arc runs: each corner's quadratic
/// is sampled at `t = 0 ..= FLATTEN_STEPS`, matching `rounded_rect_path`'s
/// control points and clamping (`rx.min(w/2)`, `ry.min(h/2)`) so the emitted
/// points trace the outline the renderer draws.
///
/// This is the machine-readable answer to "which emitted points belong to
/// corner i" — needed both by the promotion (which corner's points a drag
/// translates) and by `Controller::move_selection` (which polygon indices a
/// mid-drag corner selection remaps onto).
pub fn rounded_rect_corner_runs(
    x: f64, y: f64, w: f64, h: f64, rx_in: f64, ry_in: f64,
) -> [Vec<(f64, f64)>; 4] {
    // Clamp exactly as `rounded_rect_path` does, so promotion and render
    // agree on the shape (WYSIWYG at promotion).
    let (rx, ry) = if rx_in <= 0.0 && ry_in <= 0.0 {
        (0.0, 0.0)
    } else {
        (rx_in.max(0.0).min(w / 2.0), ry_in.max(0.0).min(h / 2.0))
    };
    if rx <= 0.0 && ry <= 0.0 {
        return [
            vec![(x, y)],
            vec![(x + w, y)],
            vec![(x + w, y + h)],
            vec![(x, y + h)],
        ];
    }
    // (start, control, end) of each corner's quadratic, walked clockwise.
    let corners = [
        ((x, y + ry), (x, y), (x + rx, y)),
        ((x + w - rx, y), (x + w, y), (x + w, y + ry)),
        ((x + w, y + h - ry), (x + w, y + h), (x + w - rx, y + h)),
        ((x + rx, y + h), (x, y + h), (x, y + h - ry)),
    ];
    corners.map(|(p0, p1, p2)| {
        (0..=FLATTEN_STEPS)
            .map(|i| {
                let t = i as f64 / FLATTEN_STEPS as f64;
                let mt = 1.0 - t;
                (
                    mt * mt * p0.0 + 2.0 * mt * t * p1.0 + t * t * p2.0,
                    mt * mt * p0.1 + 2.0 * mt * t * p1.1 + t * t * p2.1,
                )
            })
            .collect()
    })
}

/// Remap a control-point selection across a `move_control_points` call that
/// changed the element's REPRESENTATION.
///
/// A corner drag is a MULTI-SAMPLE gesture: `doc.translate_selection` feeds an
/// incremental delta per mousemove against the LIVE document
/// (workspace/tools/partial_selection.yaml), so the promotion happens on the
/// first sample and every later sample lands on the promoted element. Rect ->
/// Polygon used to emit four points, so a corner index survived by accident.
/// Once the rounding flattens into arc runs it does not: corner `i` becomes a
/// RUN of indices, and without this remap the second sample would drag a
/// single arc point and shred the corner.
///
/// Returns `kind` unchanged for every other transition — this is a remap for
/// the one promotion that changes the control-point count, not a general
/// inference from geometry.
pub fn remap_cp_selection_after_move(
    before: &Element,
    after: &Element,
    kind: &SelectionKind,
) -> SelectionKind {
    let (Element::Rect(r), Element::Polygon(_)) = (before, after) else {
        return kind.clone();
    };
    let SelectionKind::Partial(_) = kind else {
        return kind.clone();
    };
    let runs = rounded_rect_corner_runs(r.x, r.y, r.width, r.height, r.rx, r.ry);
    let mut out: Vec<usize> = Vec::new();
    let mut base = 0usize;
    for (i, run) in runs.iter().enumerate() {
        if kind.contains(i) {
            out.extend(base..base + run.len());
        }
        base += run.len();
    }
    SelectionKind::Partial(crate::document::document::SortedCps::from_iter(out))
}

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
/// Recursively clears the stable `id` on `elem` and all of its descendants.
/// A DUPLICATED element must not inherit the source's identity — two elements
/// cannot share an id (REFERENCE_GRAPH.md §2.5), and a duplicate that did
/// would be worse than a loud break: a reference to the shared id silently
/// REBINDS to whichever element the index walk reaches first
/// (transcripts/EDIT_SEMANTICS_FREEZE.md §3.7). So a copy is born id-less
/// (lazy) and mints a fresh id only if/when it later becomes a reference
/// target. `id: None` is the documented default T3 allows in place of a
/// mint; the SPLIT arms mint instead, because there the source's identity
/// died and something has to stand in its place.
///
/// The walk mirrors `Document::element_ids`: it descends `children()` AND a
/// compound shape's owned `operands`, which `Element::children()` does not
/// expose. It used to walk `children()` alone, so copying a compound shape
/// cleared the compound's own id and left every OPERAND id duplicated, one
/// level below the id this helper exists to clear.
///
/// Callers: `Controller::copy_selection` and `artboard_duplicate_init`. NOT
/// the clipboard paste path (`workspace::clipboard::clipboard_read_and_paste`
/// pastes `translate_element(...)`, which is `..e.clone()`, id included) —
/// this doc comment used to claim "every duplication path (copy, paste,
/// duplicate)", which was never true of paste. See the stable-identity
/// initiative (VISION.md §6.2).
pub fn clear_ids(elem: &mut Element) {
    elem.common_mut().id = None;
    if let Some(children) = elem.children_mut() {
        for child in children.iter_mut() {
            clear_ids(Rc::make_mut(child));
        }
    }
    if let Element::Live(super::live::LiveVariant::CompoundShape(cs)) = elem {
        for operand in cs.operands.iter_mut() {
            clear_ids(Rc::make_mut(operand));
        }
    }
}

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
                // Convert to polygon when individual corners are moved.
                //
                // RATIFIED ANSWER (3) of the preservation-law freeze
                // (transcripts/EDIT_SEMANTICS_FREEZE.md §8, JYH 2026-07-27):
                // `rx`/`ry` have NO counterpart on Polygon (T2 shape 4), and
                // the ruling is to FLATTEN the rounding into the emitted
                // points — WYSIWYG at promotion, rather than the rounding
                // silently evaporating. `rounded_rect_corner_runs` returns
                // one point run per corner in control-point order, so a
                // dragged corner translates its WHOLE arc; a square rect
                // yields four one-point runs, i.e. exactly the four corners
                // this arm has always emitted.
                let runs = rounded_rect_corner_runs(
                    e.x, e.y, e.width, e.height, e.rx, e.ry,
                );
                let mut pts: Vec<(f64, f64)> = Vec::new();
                for (i, run) in runs.iter().enumerate() {
                    let moved = kind.contains(i);
                    for &(px, py) in run {
                        pts.push(if moved { (px + dx, py + dy) } else { (px, py) });
                    }
                }
                // §3.1 under T1's REPRESENTATION term: every field with a
                // counterpart in the output kind is preserved. Both gradients
                // have one, and hard-coding `None` here was the Rust-ward
                // divergence the freeze names — a gradient-filled rounded
                // rect lost both on a corner drag.
                Element::Polygon(PolygonElem {
                    points: pts,
                    fill: e.fill,
                    stroke: e.stroke,
                    common: e.common.clone(),
                    fill_gradient: e.fill_gradient.clone(),
                    stroke_gradient: e.stroke_gradient.clone(),
                })
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
        // A polyline's control points are its points, exactly as a polygon's
        // are — the only difference between the two kinds is whether the run
        // closes. This arm was simply ABSENT: a polyline fell to the catch-all
        // and did not move, whole or by control point. Found by
        // `move_all_equals_translate_for_every_kind` while fixing the
        // container arms below, not by a report.
        Element::Polyline(e) => {
            let mut new_pts = e.points.clone();
            for i in 0..new_pts.len() {
                if kind.contains(i) {
                    new_pts[i].0 += dx;
                    new_pts[i].1 += dy;
                }
            }
            Element::Polyline(PolylineElem {
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
        Element::Text(e) => {
            // Whole-element drag (kind=All): translate. Single-corner
            // drag: scale font-size / width / height proportionally
            // about the opposite corner so the fixed corner stays
            // anchored. Mirrors the Swift implementation.
            if kind.is_all(4) {
                let mut new = e.clone();
                new.x += dx;
                new.y += dy;
                return Element::Text(new);
            }
            let corner_idx = (0..4).find(|i| kind.contains(*i));
            let Some(ci) = corner_idx else { return elem.clone(); };
            let (bx, by, bw, bh) = elem.bounds();
            let corners = [
                (bx, by), (bx + bw, by),
                (bx + bw, by + bh), (bx, by + bh),
            ];
            let opp = corners[(ci + 2) % 4];
            let cur = corners[ci];
            let nx = cur.0 + dx;
            let ny = cur.1 + dy;
            let old_diag = ((cur.0 - opp.0).powi(2) + (cur.1 - opp.1).powi(2)).sqrt();
            if old_diag <= 0.0 { return elem.clone(); }
            let new_diag = ((nx - opp.0).powi(2) + (ny - opp.1).powi(2)).sqrt();
            let scale = (new_diag / old_diag).clamp(0.1, 50.0);
            let mut new = e.clone();
            new.x = opp.0 + (e.x - opp.0) * scale;
            new.y = opp.1 + (e.y - opp.1) * scale;
            new.font_size = e.font_size * scale;
            new.width = e.width * scale;
            new.height = e.height * scale;
            Element::Text(new)
        }
        // A reference has no geometry of its own, so a whole-element move
        // (kind=All) rides on common.transform — the only thing to move.
        // The render seams already apply common.transform to a reference,
        // so this makes the move visible without any render change. (A
        // partial / control-point move is meaningless for a reference, so
        // it falls through to clone like Group/Layer/CompoundShape.)
        Element::Live(super::live::LiveVariant::Reference(r)) if kind.is_all(0) => {
            let mut new_r = r.clone();
            let existing = new_r.common.transform.unwrap_or_default();
            new_r.common.transform = Some(existing.translated(dx, dy));
            Element::Live(super::live::LiveVariant::Reference(new_r))
        }
        // CONTAINERS AND THE REMAINING LIVE KINDS. A container has no control
        // points of its own, so a selection of it is always a selection of the
        // whole subtree, and moving it moves its members. `translate_element`
        // already knows how to do that for every one of these kinds (it is the
        // paste and Align path), so delegate rather than re-derive.
        //
        // Without this arm a Group fell through to `_ => elem.clone()` and a
        // group selected as ONE entry DID NOT MOVE — measured 2026-07-29, in
        // both ports. The Selection tool puts exactly one entry in the
        // selection on a click (`selection.yaml` `doc.set_selection`), and
        // `hit_test` returns the GROUP's path for a click inside a group's
        // child, so this was every click-and-drag of a group. Rust hid it
        // because `doc.set_selection` expands a container to its descendants
        // (`interpreter/effects.rs`) and the CHILDREN moved themselves;
        // JasSwift, which does not expand, could not drag a group at all.
        //
        // That expansion is what LAYER_STRUCTURE.md §20 rules should be
        // removed, which would have carried the defect into Rust as well. See
        // `move_all_equals_translate_for_every_kind` for the invariant.
        // The predicate is the element's OWN control-point count, not zero.
        // DOCUMENT.md's table grants a Group FOUR bbox-corner control points,
        // so "fully selected" has two valid spellings -- `All`, and
        // `Partial([0,1,2,3])`, which is what `kind.to_sorted(
        // control_point_count(elem))` produces from an `All` entry. Guarding on
        // `is_all(0)` accepted only the first, so the second fell to the
        // catch-all and THE GROUP DID NOT MOVE: the very defect this arm was
        // added to fix, still armed one layer down.
        //
        // A PARTIAL container selection (one corner) is a resize gesture, not a
        // move, and group resize does not exist -- it correctly falls through.
        Element::Group(_)
        | Element::Layer(_)
        | Element::Live(_) if kind.is_all(control_point_count(elem)) => {
            translate_element(elem, dx, dy)
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
            // A reference has no geometry of its own to translate; its
            // move rides on common.transform (the live render seam applies
            // it). Mirrors the Reference arm in move_control_points.
            super::live::LiveVariant::Reference(r) => {
                let mut new_r = r.clone();
                let existing = new_r.common.transform.unwrap_or_default();
                new_r.common.transform = Some(existing.translated(dx, dy));
                Element::Live(super::live::LiveVariant::Reference(new_r))
            }
            // A recorded element's geometry is replayed from its inputs; its
            // own move rides on common.transform, like a reference.
            super::live::LiveVariant::Recorded(rec) => {
                let mut new_rec = rec.clone();
                let existing = new_rec.common.transform.unwrap_or_default();
                new_rec.common.transform = Some(existing.translated(dx, dy));
                Element::Live(super::live::LiveVariant::Recorded(new_rec))
            }
            // A generated element's geometry comes from its concept; its own
            // move rides on common.transform, like a reference.
            super::live::LiveVariant::Generated(ge) => {
                let mut new_ge = ge.clone();
                let existing = new_ge.common.transform.unwrap_or_default();
                new_ge.common.transform = Some(existing.translated(dx, dy));
                Element::Live(super::live::LiveVariant::Generated(new_ge))
            }
        },
    }
}

/// Return a copy of the element with its `fill_gradient` replaced.
/// Elements that do not support a fill gradient (Line, Text, TextPath,
/// Group, Layer, Live) are returned unchanged.
/// Apply a per-element rewrite to every PAINTABLE element a selection entry
/// reaches: the element itself when it is a leaf, or every leaf beneath it when
/// it is a container, at any depth.
///
/// RULED 2026-07-29 (JYH at council: *"yes, recurse into members"*). Selecting a
/// group and clicking a swatch is the commonest operation in the application and
/// it did nothing, because `with_fill` and its siblings return a container
/// unchanged — correct for the data model (a group carries no fill of its own)
/// and wrong for the artist's intent.
///
/// **The recursion lives HERE and not inside `with_fill`/`with_stroke`.** Those
/// are also called at render time (`canvas/render.rs` scales a stroke for
/// display) and on symbol-instance overrides, where recursing would be wrong or
/// wasteful. Only "apply this to the selection" wants the walk.
///
/// Containers are rebuilt clone-then-mutate (`..e.clone()`), so a container's own
/// `id`, `name`, `mask`, blending flags and transform survive the walk — the T4
/// bystander clause of the PRESERVATION LAW.
///
/// NOTE: this does NOT skip locked descendants. Lock enforcement is §15's job
/// and is not built yet; no other selection operation respects it either, and a
/// lone exception here would be an inconsistency rather than a protection.
/// Visit every PAINTABLE element a selection entry reaches: the element itself
/// when it is a leaf, or every leaf beneath it when it is a container.
///
/// The READ twin of `map_paintable`. The panels summarise a selection through
/// `selection_fill_summary` / `selection_stroke_summary`, which read a
/// container's OWN `fill()`/`stroke()` -- always `None` -- so a selected group
/// reported "no stroke" rather than summarising its members. A wrong answer
/// rather than an unavailable one, and since the paint ruling (fill and stroke
/// recurse into members) an artist meets it directly: set a group's stroke and
/// the panel says it has none.
///
/// An EMPTY container visits nothing, so it contributes no value to a summary.
pub fn for_each_paintable(elem: &Element, f: &mut dyn FnMut(&Element)) {
    match elem {
        Element::Group(e) => {
            for c in &e.children {
                for_each_paintable(c, f);
            }
        }
        Element::Layer(e) => {
            for c in &e.children {
                for_each_paintable(c, f);
            }
        }
        _ => f(elem),
    }
}

/// The leaf a possibly-container element SPEAKS WITH when an operation reads
/// its paint: itself when it is a leaf, its FIRST paintable leaf at any depth
/// when it is a container, and `None` when it is an EMPTY container -- which
/// has no member to speak for and contributes no geometry either.
///
/// The single-value twin of [`for_each_paintable`], deliberately identical in
/// structure: the same two container arms, the same leaf arm, the same
/// depth-first order. It cannot be written as a call to `for_each_paintable`
/// because that callback takes a higher-ranked `&Element` which cannot escape
/// the closure -- so the two must be kept in step by hand, and
/// `first_paintable_agrees_with_for_each_paintable` is what keeps them there.
///
/// WHY THE FIRST rather than the frontmost member: it is the leaf
/// `selection_fill_summary` already reports for that container, so the answer
/// the Fill/Stroke panel shows for a selected group is the answer an operation
/// on that group produces. A container whose members disagree reads `Mixed` in
/// the panel and takes this leaf's paint in an operation; electing a different
/// member would make the panel and the product tell the artist two stories.
pub fn first_paintable(elem: &Element) -> Option<&Element> {
    match elem {
        Element::Group(e) => e.children.iter().find_map(|c| first_paintable(c)),
        Element::Layer(e) => e.children.iter().find_map(|c| first_paintable(c)),
        _ => Some(elem),
    }
}

/// [`Element::fill`] RESOLVED THROUGH A CONTAINER: a leaf's own fill, or the
/// fill of the leaf its container speaks with.
///
/// The accessors themselves stay leaf-only on purpose. `fill()` / `stroke()`
/// are read by render, hit-test and the panels, and giving a container a paint
/// OF ITS OWN would change all three at once; the container answer belongs
/// here and in the selection summaries. See BOARD-boolean-container-fill:
/// applying BOOLEAN.md's settled "the frontmost operand's fill" to a container
/// through the bare accessor produced unpainted, unstroked artwork.
pub fn resolved_fill(elem: &Element) -> Option<Fill> {
    first_paintable(elem).and_then(|leaf| leaf.fill().copied())
}

/// [`Element::stroke`] resolved through a container. The twin of
/// [`resolved_fill`], and it exists for the same reason in the same words:
/// `stroke()` has the identical ten arms and the identical `_ => None`, and
/// every caller that reads a possibly-container element's fill sits one line
/// above one that reads its stroke.
pub fn resolved_stroke(elem: &Element) -> Option<Stroke> {
    first_paintable(elem).and_then(|leaf| leaf.stroke().copied())
}

/// The three stroke-PROFILE fields a `Polygon` has no slot for, resolved
/// through a container exactly as [`resolved_fill`] resolves paint.
///
/// `None` when the source carries none of them — which is the common case, and
/// keeps a profile-less survivor demoting to `Polygon` exactly as before. When
/// it is `Some`, a boolean survivor MUST emit `Path`: EDIT_SEMANTICS_FREEZE.md
/// §3.5 rules the demotion a VIOLATION of §3.1 for the 1->1 arms, because the
/// output representation has nowhere to put these ("emit the survivor's own
/// kind or Path, the superset, never a lossy demotion" — T1's representation
/// term).
pub fn resolved_stroke_profile(elem: &Element) -> Option<StrokeProfile> {
    let leaf = first_paintable(elem)?;
    let Element::Path(p) = leaf else { return None };
    if p.width_points.is_empty()
        && p.stroke_brush.is_none()
        && p.stroke_brush_overrides.is_none()
    {
        return None;
    }
    Some(StrokeProfile {
        width_points: p.width_points.clone(),
        stroke_brush: p.stroke_brush.clone(),
        stroke_brush_overrides: p.stroke_brush_overrides.clone(),
    })
}

/// What [`resolved_stroke_profile`] carries: the fields that make a survivor
/// un-demotable.
#[derive(Debug, Clone, PartialEq)]
pub struct StrokeProfile {
    pub width_points: Vec<StrokeWidthPoint>,
    pub stroke_brush: Option<String>,
    pub stroke_brush_overrides: Option<String>,
}

pub fn map_paintable(elem: &Element, f: &dyn Fn(&Element) -> Element) -> Element {
    match elem {
        Element::Group(e) => Element::Group(GroupElem {
            children: e.children.iter().map(|c| Rc::new(map_paintable(c, f))).collect(),
            ..e.clone()
        }),
        Element::Layer(e) => Element::Layer(LayerElem {
            children: e.children.iter().map(|c| Rc::new(map_paintable(c, f))).collect(),
            ..e.clone()
        }),
        _ => f(elem),
    }
}

pub fn with_fill_gradient(elem: &Element, gradient: Option<Box<Gradient>>) -> Element {
    match elem {
        Element::Rect(e) => Element::Rect(RectElem { fill_gradient: gradient, ..e.clone() }),
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
            super::live::LiveVariant::Reference(r) => Element::Live(
                super::live::LiveVariant::Reference(super::live::ReferenceElem {
                    fill,
                    ..r.clone()
                }),
            ),
            super::live::LiveVariant::Recorded(rec) => Element::Live(
                super::live::LiveVariant::Recorded(super::live::RecordedElem {
                    fill,
                    ..rec.clone()
                }),
            ),
            super::live::LiveVariant::Generated(ge) => Element::Live(
                super::live::LiveVariant::Generated(super::live::GeneratedElem {
                    fill,
                    ..ge.clone()
                }),
            ),
        },
    }
}

/// Promote a Line (or open Polyline) to a geometry-identical Path so it
/// can carry Path-only attributes such as `stroke_brush`. This mirrors
/// the Rect→Polygon corner-drag promotion (see `move_control_points`,
/// the "upgrade naturally" convention ratified by JYH 2026-07-25):
/// identity is preserved (the caller replaces the element in place at its
/// tree path), the common props (name, id, opacity, transform,
/// visibility, lock, mask, blend mode, tool_origin) are carried WHOLE via
/// `common`, and the stroke + width profile carry whole too. A Line has
/// no fill, so the Path's fill is None; a Polyline's fill and gradients
/// carry across. Non-promotable elements (including a degenerate Polyline
/// with fewer than two points) return unchanged. See BRUSHES.md §Stroke
/// styling interaction.
pub fn promote_to_path_for_brush(elem: &Element) -> Element {
    match elem {
        Element::Line(e) => Element::Path(PathElem {
            d: vec![
                PathCommand::MoveTo { x: e.x1, y: e.y1 },
                PathCommand::LineTo { x: e.x2, y: e.y2 },
            ],
            fill: None,
            stroke: e.stroke,
            width_points: e.width_points.clone(),
            common: e.common.clone(),
            fill_gradient: None,
            stroke_gradient: e.stroke_gradient.clone(),
            fill_rule: FillRule::default(),
            stroke_brush: None,
            stroke_brush_overrides: None,
        }),
        Element::Polyline(e) if e.points.len() >= 2 => {
            let mut d = Vec::with_capacity(e.points.len());
            d.push(PathCommand::MoveTo { x: e.points[0].0, y: e.points[0].1 });
            for p in &e.points[1..] {
                d.push(PathCommand::LineTo { x: p.0, y: p.1 });
            }
            Element::Path(PathElem {
                d,
                fill: e.fill,
                stroke: e.stroke,
                width_points: Vec::new(),
                common: e.common.clone(),
                fill_gradient: e.fill_gradient.clone(),
                stroke_gradient: e.stroke_gradient.clone(),
                fill_rule: FillRule::default(),
                stroke_brush: None,
                stroke_brush_overrides: None,
            })
        }
        _ => elem.clone(),
    }
}

/// Return a copy of the element with its stroke_brush replaced.
/// A Path carries the brush directly. Applying a brush (a `Some` slug) to
/// a Line or open Polyline PROMOTES it to a geometry-identical Path that
/// then carries the brush — the "upgrade naturally" convention (JYH
/// 2026-07-25); see `promote_to_path_for_brush`. Clearing (`None`) is not
/// a brush application, so it never promotes. Other elements are returned
/// unchanged. See BRUSHES.md §Stroke styling interaction.
pub fn with_stroke_brush(elem: &Element, stroke_brush: Option<String>) -> Element {
    match elem {
        Element::Path(e) => Element::Path(PathElem { stroke_brush, ..e.clone() }),
        Element::Line(_) | Element::Polyline(_) if stroke_brush.is_some() => {
            match promote_to_path_for_brush(elem) {
                Element::Path(p) => Element::Path(PathElem { stroke_brush, ..p }),
                other => other,
            }
        }
        _ => elem.clone(),
    }
}

/// Return a copy of the element with its stroke_brush_overrides
/// replaced. A Path carries it directly; a Line / open Polyline is
/// promoted to a Path first when the value is `Some` (mirrors
/// `with_stroke_brush`). Clearing (`None`) never promotes.
pub fn with_stroke_brush_overrides(elem: &Element, overrides: Option<String>) -> Element {
    match elem {
        Element::Path(e) => Element::Path(PathElem { stroke_brush_overrides: overrides, ..e.clone() }),
        Element::Line(_) | Element::Polyline(_) if overrides.is_some() => {
            match promote_to_path_for_brush(elem) {
                Element::Path(p) => Element::Path(PathElem { stroke_brush_overrides: overrides, ..p }),
                other => other,
            }
        }
        _ => elem.clone(),
    }
}

/// Return a copy of the element with its stroke replaced.
/// Elements that do not support stroke (Group, Layer) are returned unchanged.
pub fn with_stroke(elem: &Element, stroke: Option<Stroke>) -> Element {
    match elem {
        Element::Line(e) => Element::Line(LineElem { stroke, ..e.clone() }),
        Element::Rect(e) => Element::Rect(RectElem { stroke, ..e.clone() }),
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
            super::live::LiveVariant::Reference(r) => Element::Live(
                super::live::LiveVariant::Reference(super::live::ReferenceElem {
                    stroke,
                    ..r.clone()
                }),
            ),
            super::live::LiveVariant::Recorded(rec) => Element::Live(
                super::live::LiveVariant::Recorded(super::live::RecordedElem {
                    stroke,
                    ..rec.clone()
                }),
            ),
            super::live::LiveVariant::Generated(ge) => Element::Live(
                super::live::LiveVariant::Generated(super::live::GeneratedElem {
                    stroke,
                    ..ge.clone()
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

    /// THE INVARIANT: for an ALL selection, moving is translating.
    ///
    /// `move_control_points` and `translate_element` are two spellings of the
    /// same idea — the first takes a control-point subset, the second always
    /// means the whole element. When the subset IS the whole element they must
    /// agree, for every kind. They did not: `move_control_points` had no arm
    /// for `Group`, `Layer` or the non-Reference `Live` kinds, so those fell to
    /// its catch-all `elem.clone()` and DID NOT MOVE, while `translate_element`
    /// moved them correctly. A group selected as one entry could not be dragged.
    ///
    /// This is asserted per KIND rather than per bug so the next kind added to
    /// one function and forgotten in the other reds here instead of shipping.
    /// Twin: JasSwift `GroupMoveProbeTests`.
    #[test]
    fn move_all_equals_translate_for_every_kind() {
        use std::rc::Rc;
        let leaf = Element::Rect(RectElem {
            x: 3.0, y: 4.0, width: 10.0, height: 10.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let line = Element::Line(LineElem {
            x1: 0.0, y1: 0.0, x2: 5.0, y2: 5.0, stroke: None,
            width_points: Vec::new(), common: CommonProps::default(),
            stroke_gradient: None,
        });
        let kinds: Vec<(&str, Element)> = vec![
            ("rect", leaf.clone()),
            ("line", line.clone()),
            ("polyline", Element::Polyline(PolylineElem {
                points: vec![(0.0, 0.0), (1.0, 2.0)], stroke: None,
                common: CommonProps::default(),
                fill: None, fill_gradient: None, stroke_gradient: None,
            })),
            ("group", Element::Group(GroupElem {
                children: vec![Rc::new(leaf.clone()), Rc::new(line.clone())],
                isolated_blending: false, knockout_group: false,
                common: CommonProps::default(),
            })),
            ("layer", Element::Layer(LayerElem {
                children: vec![Rc::new(leaf.clone())],
                isolated_blending: false, knockout_group: false,
                common: CommonProps::default(),
            })),
            ("nested group", Element::Group(GroupElem {
                children: vec![Rc::new(Element::Group(GroupElem {
                    children: vec![Rc::new(leaf.clone())],
                    isolated_blending: false, knockout_group: false,
                    common: CommonProps::default(),
                }))],
                isolated_blending: false, knockout_group: false,
                common: CommonProps::default(),
            })),
        ];
        let (dx, dy) = (10.0, 20.0);
        let mut disagreed = Vec::new();
        for (name, elem) in &kinds {
            let moved = move_control_points(elem, &SelectionKind::All, dx, dy);
            let translated = translate_element(elem, dx, dy);
            if moved != translated {
                let stationary = moved == *elem;
                disagreed.push(format!(
                    "  {name}: move_control_points(All) != translate_element{}",
                    if stationary { " — it did not move AT ALL" } else { "" }
                ));
            }
        }
        assert!(
            disagreed.is_empty(),
            "moving with an ALL selection must equal translating:\n{}",
            disagreed.join("\n")
        );
    }

    /// `first_paintable` is `for_each_paintable`'s first visit, and the two are
    /// written separately because a higher-ranked closure argument cannot
    /// escape. Nothing but this test keeps them in step: a container kind added
    /// to one walk and forgotten in the other would make the panels summarise a
    /// group the boolean ops cannot paint.
    #[test]
    fn first_paintable_agrees_with_for_each_paintable() {
        use std::rc::Rc;
        let rect = |x: f64| Element::Rect(RectElem {
            x, y: 0.0, width: 1.0, height: 1.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: None, common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let group = |kids: Vec<Element>| Element::Group(GroupElem {
            children: kids.into_iter().map(Rc::new).collect(),
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let layer = |kids: Vec<Element>| Element::Layer(LayerElem {
            children: kids.into_iter().map(Rc::new).collect(),
            isolated_blending: false, knockout_group: false,
            common: CommonProps::default(),
        });
        let cases: Vec<(&str, Element)> = vec![
            ("leaf", rect(1.0)),
            ("group of two", group(vec![rect(2.0), rect(3.0)])),
            ("layer", layer(vec![rect(4.0)])),
            ("nested", group(vec![group(vec![rect(5.0)]), rect(6.0)])),
            // The degenerate ends: an empty container speaks for nobody, and a
            // container holding only empty containers is the same answer one
            // level down.
            ("empty group", group(vec![])),
            ("group of empties", group(vec![group(vec![]), layer(vec![])])),
        ];
        for (name, elem) in &cases {
            let mut visited: Vec<f64> = Vec::new();
            for_each_paintable(elem, &mut |leaf| {
                if let Element::Rect(r) = leaf { visited.push(r.x) }
            });
            let first = first_paintable(elem).and_then(|l| match l {
                Element::Rect(r) => Some(r.x),
                _ => None,
            });
            assert_eq!(first, visited.first().copied(),
                       "`{name}`: first_paintable must be for_each_paintable's \
                        FIRST visit, and `None` exactly when it visits nothing");
        }
    }

    /// Risk R9 (transcripts/CORPUS_CENSUS.md §7): a non-finite hue must be
    /// sanitised to 0 here, not carried into the components. Unsanitised, `as
    /// u32` gives sector 0 and then `f` is NaN, so two of the three returned
    /// components are NaN; JasSwift's `Int(floor(h / 60.0))` is a precondition
    /// failure on the same input. Twin: JasSwift's
    /// `R9ColourChainTests.nonFiniteHueIsTreatedAsZero`.
    #[test]
    fn non_finite_hue_is_treated_as_zero() {
        let (r, g, b, a) = Color::hsb(f64::NAN, 1.0, 0.8).to_rgba();
        assert_eq!((r, g, b, a), (0.8, 0.0, 0.0, 1.0));
        let (r, g, b, _) = Color::hsb(f64::INFINITY, 1.0, 0.8).to_rgba();
        assert_eq!((r, g, b), (0.8, 0.0, 0.0));
        assert_eq!(Color::hsb(f64::NAN, 1.0, 0.8).to_hex(), "cc0000");
        // A finite out-of-range hue still WRAPS — the guard must not eat it.
        assert_eq!(
            Color::hsb(480.0, 1.0, 1.0).to_rgba(),
            Color::hsb(120.0, 1.0, 1.0).to_rgba()
        );
    }

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
        Element::Ellipse(EllipseElem {
            cx, cy, rx: r, ry: r,
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
            fill_rule: crate::geometry::element::FillRule::NonZero,
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

    /// Build a bare reference to ``target`` with no common.transform.
    fn make_reference(target: &str) -> Element {
        Element::Live(super::super::live::LiveVariant::Reference(
            super::super::live::ReferenceElem::new(
                super::super::live::ElementRef(target.to_string()),
                CommonProps::default(),
            ),
        ))
    }

    /// A reference has no geometry of its own; a whole-element move rides
    /// on common.transform (the live render seam applies it). Moving an
    /// id-less-transform reference yields a translate(dx, dy).
    #[test]
    fn move_reference_all_sets_common_transform() {
        let r = make_reference("tgt");
        let moved = move_control_points(&r, &SelectionKind::All, 24.0, 24.0);
        if let Element::Live(super::super::live::LiveVariant::Reference(re)) = moved {
            let t = re.common.transform.expect("common.transform should be set");
            assert_eq!((t.a, t.b, t.c, t.d, t.e, t.f), (1.0, 0.0, 0.0, 1.0, 24.0, 24.0));
            // The dead instance-transform field stays untouched (None).
            assert!(re.transform.is_none());
        } else {
            panic!("expected a Reference");
        }
    }

    /// A second move composes onto the existing common.transform: the two
    /// translations sum (translated() only touches e/f).
    #[test]
    fn move_reference_composes_onto_existing_transform() {
        let r = make_reference("tgt");
        let once = move_control_points(&r, &SelectionKind::All, 10.0, 5.0);
        let twice = move_control_points(&once, &SelectionKind::All, 4.0, 7.0);
        if let Element::Live(super::super::live::LiveVariant::Reference(re)) = twice {
            let t = re.common.transform.expect("common.transform should be set");
            assert_eq!((t.e, t.f), (14.0, 12.0));
        } else {
            panic!("expected a Reference");
        }
    }

    /// translate_element mirrors move_control_points for references: it
    /// rides on common.transform too (used by paste / copy / group paths).
    #[test]
    fn translate_reference_sets_common_transform() {
        let r = make_reference("tgt");
        let moved = translate_element(&r, 24.0, 24.0);
        if let Element::Live(super::super::live::LiveVariant::Reference(re)) = moved {
            let t = re.common.transform.expect("common.transform should be set");
            assert_eq!((t.e, t.f), (24.0, 24.0));
            assert!(re.transform.is_none());
        } else {
            panic!("expected a Reference");
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

    // S-4: a leading ClosePath is a no-op. Ruled by JYH at the fleet
    // council, 2026-07-27 -- a ClosePath appearing before any point has
    // been established contributes nothing and must not emit a point.
    //
    // Rust already implemented the ruling when these were written, so
    // unlike their Swift counterparts these went in GREEN: they are
    // regression pins for a guard that had no in-suite test at all
    // (`flatten_multi_subpath_closes_to_subpath_start` is the closest
    // existing test and never reaches the guard's empty branch).
    //
    // The FOUR leading-close tests were shown to discriminate by deleting
    // the `!pts.is_empty()` condition: exactly those four then fail. The
    // two scope-boundary tests below do NOT fail under that deletion --
    // they are pinned against different wrong implementations, and each
    // names its own in its own doc comment.

    /// A path that is nothing but Z flattens to nothing. Without the
    /// guard this returns the uninitialised subpath start, [(0, 0)].
    #[test]
    fn flatten_leading_close_alone_emits_nothing() {
        assert!(flatten_path_commands(&[PathCommand::ClosePath]).is_empty());
    }

    /// A leading Z contributes nothing, so a following LineTo is the only
    /// point. Without the guard this returns [(0, 0), (5, 5)].
    #[test]
    fn flatten_leading_close_then_line_to() {
        let pts = flatten_path_commands(&[
            PathCommand::ClosePath,
            PathCommand::LineTo { x: 5.0, y: 5.0 },
        ]);
        assert_eq!(pts, vec![(5.0, 5.0)]);
    }

    /// A leading Z in front of a real subpath: the leading close is a
    /// no-op, the trailing close still returns to the MoveTo (4, 1). The
    /// MoveTo is deliberately off the origin so the phantom point differs
    /// by value as well as by count. Without the guard this returns 5
    /// points led by (0, 0).
    #[test]
    fn flatten_leading_close_then_closed_subpath() {
        let pts = flatten_path_commands(&[
            PathCommand::ClosePath,
            PathCommand::MoveTo { x: 4.0, y: 1.0 },
            PathCommand::LineTo { x: 14.0, y: 1.0 },
            PathCommand::LineTo { x: 14.0, y: 11.0 },
            PathCommand::ClosePath,
        ]);
        assert_eq!(pts, vec![(4.0, 1.0), (14.0, 1.0), (14.0, 11.0), (4.0, 1.0)]);
    }

    /// A leading Z in front of TWO subpaths: each real close still returns
    /// to its OWN subpath start. Without the guard this returns 7 points
    /// led by (0, 0).
    #[test]
    fn flatten_leading_close_multi_subpath() {
        let pts = flatten_path_commands(&[
            PathCommand::ClosePath,
            PathCommand::MoveTo { x: 3.0, y: 2.0 },
            PathCommand::LineTo { x: 13.0, y: 2.0 },
            PathCommand::ClosePath,
            PathCommand::MoveTo { x: 23.0, y: 2.0 },
            PathCommand::LineTo { x: 33.0, y: 2.0 },
            PathCommand::ClosePath,
        ]);
        assert_eq!(
            pts,
            vec![(3.0, 2.0), (13.0, 2.0), (3.0, 2.0), (23.0, 2.0), (33.0, 2.0), (23.0, 2.0)]
        );
    }

    /// SCOPE BOUNDARY, and not a discriminator for the leading-close bug.
    /// After M, L a point IS established, so the ruling does not reach the
    /// second Z and it still emits the subpath start. Guarding the close
    /// on last-point-inequality instead of on emptiness returns 3 points.
    #[test]
    fn flatten_redundant_trailing_close_still_emits() {
        let pts = flatten_path_commands(&[
            PathCommand::MoveTo { x: 2.0, y: 3.0 },
            PathCommand::LineTo { x: 12.0, y: 3.0 },
            PathCommand::ClosePath,
            PathCommand::ClosePath,
        ]);
        assert_eq!(pts, vec![(2.0, 3.0), (12.0, 3.0), (2.0, 3.0), (2.0, 3.0)]);
    }

    /// SCOPE BOUNDARY, and likewise not a discriminator for the
    /// leading-close bug. One MoveTo has established a point, so the
    /// following Z is not a leading close and does emit. Requiring two
    /// points before closing returns 1.
    #[test]
    fn flatten_move_to_then_close_still_emits() {
        let pts = flatten_path_commands(&[
            PathCommand::MoveTo { x: 6.0, y: 7.0 },
            PathCommand::ClosePath,
        ]);
        assert_eq!(pts, vec![(6.0, 7.0), (6.0, 7.0)]);
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
            fill_rule: crate::geometry::element::FillRule::NonZero,
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
            children: Vec::new(),
            isolated_blending: false,
            knockout_group: false,
            common: CommonProps { opacity: 0.75, mode: BlendMode::Normal,
                                  transform: None, locked: true,
                                  visibility: Visibility::Outline, mask: None,
                                  tool_origin: None,
                                  name: Some("Layer 1".into()), id: None },
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
            name: None,
            id: None,
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
            name: None,
            id: None,
            },
                    fill_gradient: None,
            stroke_gradient: None,
        });
        let json = serde_json::to_value(&elem).unwrap();
        let back: Element = serde_json::from_value(json).unwrap();
        assert_eq!(elem, back);
        assert_eq!(back.mode(), BlendMode::Multiply);
    }

    /// Quarter circle from (10, 0) to (0, 10) sweeping through (0, 0):
    /// rx=ry=10, large_arc=false, sweep=false (counterclockwise).
    /// The arc passes through the origin which is the bbox min corner.
    #[test]
    fn arc_extrema_quarter_circle_through_origin() {
        let path = vec![
            PathCommand::MoveTo { x: 10.0, y: 0.0 },
            PathCommand::ArcTo {
                rx: 10.0, ry: 10.0, x_rotation: 0.0,
                large_arc: false, sweep: false,
                x: 0.0, y: 10.0,
            },
        ];
        let (x, y, w, h) = path_bounds(&path);
        // Without arc extrema, the bbox would be (0, 0, 10, 10) using
        // only endpoints. With proper extrema this arc bulges into
        // the negative quadrant: it sweeps through (0, 0) so x_min=0,
        // y_min=0, but the OPPOSITE arc would reach (10-rx, 10-ry).
        // Endpoints alone happen to give the right answer here, so we
        // check the more interesting case below.
        assert!((x - 0.0).abs() < 1e-6, "x={}", x);
        assert!((y - 0.0).abs() < 1e-6, "y={}", y);
        assert!((w - 10.0).abs() < 1e-6, "w={}", w);
        assert!((h - 10.0).abs() < 1e-6, "h={}", h);
    }

    /// Long-way arc from (10, 0) to (0, 10) with large_arc=true,
    /// sweep=true: SVG picks the center at (10, 10) and sweeps the
    /// 3/4 of the circle that reaches (20, 10), (10, 20), and (0, 0).
    /// The naive endpoint-only bbox would be (0, 0, 10, 10); the
    /// correct extrema-aware bbox extends to (0, 0, 20, 20).
    #[test]
    fn arc_extrema_large_arc_reaches_far_corners() {
        let path = vec![
            PathCommand::MoveTo { x: 10.0, y: 0.0 },
            PathCommand::ArcTo {
                rx: 10.0, ry: 10.0, x_rotation: 0.0,
                large_arc: true, sweep: true,
                x: 0.0, y: 10.0,
            },
        ];
        let (x, y, w, h) = path_bounds(&path);
        assert!((x - 0.0).abs() < 1e-6, "x_min={}", x);
        assert!((y - 0.0).abs() < 1e-6, "y_min={}", y);
        assert!((w - 20.0).abs() < 1e-6,
            "expected w=20 (arc reaches x=20), got w={}", w);
        assert!((h - 20.0).abs() < 1e-6,
            "expected h=20 (arc reaches y=20), got h={}", h);
    }

    #[test]
    fn render_is_flat_single_body_no_overrides() {
        let t = TextElem::from_string(
            0.0, 0.0, "hello",
            "sans-serif", 16.0, "normal", "normal", "none",
            300.0, 200.0, None, None, CommonProps::default(),
        );
        assert!(t.render_is_flat());
    }

    #[test]
    fn render_is_flat_empty_wrapper_plus_flat_body() {
        // Regression: after the Paragraph panel inserts a wrapper
        // before just-typed content the renderer must still take the
        // paragraph-aware fast path. Otherwise draw_segmented_text
        // (single-line) renders the body and the paragraph collapses.
        let mut t = TextElem::from_string(
            0.0, 0.0, "",
            "sans-serif", 16.0, "normal", "normal", "none",
            300.0, 200.0, None, None, CommonProps::default(),
        );
        t.tspans = vec![
            crate::geometry::tspan::Tspan {
                jas_role: Some("paragraph".into()),
                ..crate::geometry::tspan::Tspan::default_tspan()
            },
            crate::geometry::tspan::Tspan {
                content: "hello world".into(),
                ..crate::geometry::tspan::Tspan::default_tspan()
            },
        ];
        assert!(t.render_is_flat(),
            "wrapper+body must stay on the fast path so wrapping survives");
    }

    #[test]
    fn render_is_flat_false_when_wrapper_has_content() {
        // A wrapper carrying content is corrupt — render_is_flat
        // refuses it so the segmented path can show that something is
        // wrong rather than silently dropping the wrapper's chars.
        let mut t = TextElem::from_string(
            0.0, 0.0, "",
            "sans-serif", 16.0, "normal", "normal", "none",
            300.0, 200.0, None, None, CommonProps::default(),
        );
        t.tspans = vec![crate::geometry::tspan::Tspan {
            jas_role: Some("paragraph".into()),
            content: "should-be-empty".into(),
            ..crate::geometry::tspan::Tspan::default_tspan()
        }];
        assert!(!t.render_is_flat());
    }

    #[test]
    fn render_is_flat_false_when_body_has_font_override() {
        let mut t = TextElem::from_string(
            0.0, 0.0, "",
            "sans-serif", 16.0, "normal", "normal", "none",
            300.0, 200.0, None, None, CommonProps::default(),
        );
        t.tspans = vec![crate::geometry::tspan::Tspan {
            content: "hello".into(),
            font_weight: Some("bold".into()),
            ..crate::geometry::tspan::Tspan::default_tspan()
        }];
        assert!(!t.render_is_flat());
    }

    /// Degenerate arc (zero radius) collapses to a line; bounds match
    /// the endpoint pair.
    #[test]
    fn arc_extrema_zero_radius_is_line() {
        let path = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::ArcTo {
                rx: 0.0, ry: 0.0, x_rotation: 0.0,
                large_arc: false, sweep: false,
                x: 100.0, y: 50.0,
            },
        ];
        let (x, y, w, h) = path_bounds(&path);
        assert!((x - 0.0).abs() < 1e-6);
        assert!((y - 0.0).abs() < 1e-6);
        assert!((w - 100.0).abs() < 1e-6);
        assert!((h - 50.0).abs() < 1e-6);
    }

    /// Two disjoint squares: each ClosePath must close to the CURRENT
    /// subpath start, not the whole-path first point. Closing the second
    /// subpath back to (0,0) instead of (20,0) was the multi-subpath
    /// divergence (Python+Rust vs the SVG-correct OCaml+Swift).
    #[test]
    fn flatten_multi_subpath_closes_to_subpath_start() {
        let d = vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 10.0, y: 0.0 },
            PathCommand::LineTo { x: 10.0, y: 10.0 },
            PathCommand::LineTo { x: 0.0, y: 10.0 },
            PathCommand::ClosePath,
            PathCommand::MoveTo { x: 20.0, y: 0.0 },
            PathCommand::LineTo { x: 30.0, y: 0.0 },
            PathCommand::LineTo { x: 30.0, y: 10.0 },
            PathCommand::LineTo { x: 20.0, y: 10.0 },
            PathCommand::ClosePath,
        ];
        let pts = flatten_path_commands(&d);
        assert_eq!(pts, vec![
            (0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0), (0.0, 0.0),
            (20.0, 0.0), (30.0, 0.0), (30.0, 10.0), (20.0, 10.0), (20.0, 0.0),
        ]);
    }

    // --- Line/Polyline → Path promotion on brush apply (LINEPROMOTE) -------
    //
    // The "upgrade naturally" convention (JYH 2026-07-25), mirroring the
    // Rect→Polygon corner-drag promotion: applying a brush to a Line promotes
    // it to a geometry-identical Path that then carries the brush.

    /// A Line carrying non-default common props (id, name, opacity, transform,
    /// lock, visibility, blend mode) + a stroke and a width profile — so the
    /// promotion's "carry common + stroke whole" claim is testable.
    fn decorated_line() -> Element {
        let common = CommonProps {
            opacity: 0.5,
            mode: BlendMode::Multiply,
            transform: Some(Transform::default().translated(3.0, 4.0)),
            locked: true,
            visibility: Visibility::Outline,
            mask: None,
            tool_origin: None,
            name: Some("my line".to_string()),
            id: Some("line-7".to_string()),
        };
        Element::Line(LineElem {
            x1: 1.0, y1: 2.0, x2: 30.0, y2: 40.0,
            stroke: Some(Stroke::new(Color::rgb(0.1, 0.2, 0.3), 5.0)),
            width_points: vec![StrokeWidthPoint { t: 0.5, width_left: 2.0, width_right: 2.0 }],
            common,
            stroke_gradient: None,
        })
    }

    #[test]
    fn brush_apply_promotes_line_to_path_geometry_identical() {
        let promoted = with_stroke_brush(&decorated_line(), Some("charcoal".to_string()));
        let Element::Path(p) = promoted else {
            panic!("a brush on a Line must promote it to a Path, got {promoted:?}");
        };
        // Geometry: MoveTo(x1,y1) + LineTo(x2,y2).
        assert_eq!(p.d, vec![
            PathCommand::MoveTo { x: 1.0, y: 2.0 },
            PathCommand::LineTo { x: 30.0, y: 40.0 },
        ]);
        // The brush landed; a Line has no fill so the Path fill is None.
        assert_eq!(p.stroke_brush, Some("charcoal".to_string()));
        assert_eq!(p.fill, None);
        // Stroke + width profile carried whole.
        assert_eq!(p.stroke, Some(Stroke::new(Color::rgb(0.1, 0.2, 0.3), 5.0)));
        assert_eq!(p.width_points,
            vec![StrokeWidthPoint { t: 0.5, width_left: 2.0, width_right: 2.0 }]);
        // Common props carried WHOLE (identity + presentation preserved).
        assert_eq!(p.common.id.as_deref(), Some("line-7"));
        assert_eq!(p.common.name.as_deref(), Some("my line"));
        assert_eq!(p.common.opacity, 0.5);
        assert_eq!(p.common.mode, BlendMode::Multiply);
        assert!(p.common.locked);
        assert_eq!(p.common.visibility, Visibility::Outline);
        assert_eq!(p.common.transform, Some(Transform::default().translated(3.0, 4.0)));
    }

    #[test]
    fn brush_clear_does_not_promote_a_line() {
        // Clearing (None) is not a brush application — a Line stays a Line.
        let unchanged = with_stroke_brush(&decorated_line(), None);
        assert!(matches!(unchanged, Element::Line(_)),
            "clearing a brush must not promote a Line");
        // Same for overrides.
        let unchanged = with_stroke_brush_overrides(&decorated_line(), None);
        assert!(matches!(unchanged, Element::Line(_)));
    }

    #[test]
    fn brush_apply_promotes_polyline_carrying_fill() {
        let poly = Element::Polyline(PolylineElem {
            points: vec![(0.0, 0.0), (10.0, 5.0), (20.0, 0.0)],
            fill: Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))),
            stroke: Some(Stroke::new(Color::BLACK, 3.0)),
            common: CommonProps { id: Some("poly-1".to_string()), ..CommonProps::default() },
            fill_gradient: None,
            stroke_gradient: None,
        });
        let Element::Path(p) = with_stroke_brush(&poly, Some("charcoal".to_string())) else {
            panic!("a brush on a Polyline must promote it to a Path");
        };
        assert_eq!(p.d, vec![
            PathCommand::MoveTo { x: 0.0, y: 0.0 },
            PathCommand::LineTo { x: 10.0, y: 5.0 },
            PathCommand::LineTo { x: 20.0, y: 0.0 },
        ]);
        assert_eq!(p.stroke_brush, Some("charcoal".to_string()));
        // A Polyline's fill carries across (unlike a Line, which has none).
        assert_eq!(p.fill, Some(Fill::new(Color::rgb(1.0, 0.0, 0.0))));
        assert_eq!(p.common.id.as_deref(), Some("poly-1"));
    }

    #[test]
    fn brush_overrides_on_a_line_also_promotes() {
        let Element::Path(p) =
            with_stroke_brush_overrides(&decorated_line(), Some("{\"angle\":9}".to_string()))
        else {
            panic!("overrides on a Line must promote it to a Path");
        };
        assert_eq!(p.stroke_brush_overrides, Some("{\"angle\":9}".to_string()));
        assert_eq!(p.d, vec![
            PathCommand::MoveTo { x: 1.0, y: 2.0 },
            PathCommand::LineTo { x: 30.0, y: 40.0 },
        ]);
    }

    #[test]
    fn brush_apply_on_a_path_is_unchanged_geometry() {
        // A Path already carries the brush directly — no promotion, geometry
        // and every other field untouched but stroke_brush set.
        let path = Element::Path(PathElem {
            d: vec![PathCommand::MoveTo { x: 0.0, y: 0.0 },
                    PathCommand::LineTo { x: 5.0, y: 5.0 }],
            fill: None,
            stroke: Some(Stroke::new(Color::BLACK, 1.0)),
            width_points: Vec::new(),
            common: CommonProps::default(),
            fill_gradient: None,
            stroke_gradient: None,
            fill_rule: FillRule::default(),
            stroke_brush: None,
            stroke_brush_overrides: None,
        });
        let Element::Path(p) = with_stroke_brush(&path, Some("charcoal".to_string())) else {
            panic!("a Path stays a Path");
        };
        assert_eq!(p.stroke_brush, Some("charcoal".to_string()));
        assert_eq!(p.d.len(), 2);
    }
}

/// THE PRESERVATION LAW at the Rect -> Polygon corner-drag promotion.
/// transcripts/EDIT_SEMANTICS_FREEZE.md (ratified 2026-07-27): §3.1 (the
/// Theseus clause under T1's REPRESENTATION term — a 1 -> 1 kind change
/// preserves every field with a counterpart) and RATIFIED ANSWER (3):
/// `rx`/`ry` FLATTEN into the emitted points (WYSIWYG at promotion).
#[cfg(test)]
mod rect_promotion_preservation_tests {
    use super::*;
    use crate::document::document::{SelectionKind, SortedCps};

    /// A one-corner partial selection, the shape a corner drag arrives in.
    fn cp(i: usize) -> SelectionKind {
        SelectionKind::Partial(SortedCps::from_iter([i]))
    }

    fn a_gradient(angle: f64) -> Gradient {
        Gradient {
            angle,
            stops: vec![
                GradientStop { color: Color::BLACK, opacity: 100.0,
                               location: 0.0, midpoint_to_next: 50.0 },
                GradientStop { color: Color::WHITE, opacity: 100.0,
                               location: 100.0, midpoint_to_next: 50.0 },
            ],
            ..Gradient::default()
        }
    }

    /// A rounded, gradient-painted, named, identified rect. ANTI-VACUITY is
    /// asserted by `assert_rect_fixture_is_rich` before every use.
    fn rich_rect(rx: f64, ry: f64) -> RectElem {
        RectElem {
            x: 0.0, y: 0.0, width: 100.0, height: 60.0, rx, ry,
            fill: Some(Fill::new(Color::BLACK)),
            stroke: Some(Stroke::new(Color::BLACK, 2.0)),
            common: CommonProps {
                opacity: 0.5,
                mode: BlendMode::Multiply,
                transform: Some(Transform::default().translated(3.0, 4.0)),
                locked: false,
                visibility: Visibility::Outline,
                mask: None,
                tool_origin: Some("blob_brush".to_string()),
                name: Some("hull".to_string()),
                id: Some("rect-id".to_string()),
            },
            fill_gradient: Some(Box::new(a_gradient(30.0))),
            stroke_gradient: Some(Box::new(a_gradient(60.0))),
        }
    }

    fn assert_rect_fixture_is_rich(e: &RectElem) {
        let d = CommonProps::default();
        assert!(e.fill_gradient.is_some(), "fixture lost its fill gradient");
        assert!(e.stroke_gradient.is_some(), "fixture lost its stroke gradient");
        assert_ne!(e.common.opacity, d.opacity);
        assert_ne!(e.common.mode, d.mode);
        assert_ne!(e.common.visibility, d.visibility);
        assert_ne!(e.common.transform, d.transform);
        assert!(e.common.id.is_some());
        assert!(e.common.name.is_some());
        assert!(e.common.tool_origin.is_some());
    }

    /// §3.1 under T1's representation term. Rust hard-coded
    /// `fill_gradient: None, stroke_gradient: None` at this cross-kind copy
    /// site — the compiler demanded the field and a human answered None —
    /// so a gradient-filled rounded rect, corner-dragged, silently lost BOTH
    /// gradients. Polygon has a counterpart for each, so each is preserved.
    #[test]
    fn rect_corner_drag_preserves_both_gradients() {
        let r = rich_rect(0.0, 0.0);
        assert_rect_fixture_is_rich(&r);
        let moved = move_control_points(
            &Element::Rect(r.clone()), &cp(1), 5.0, 7.0);
        let Element::Polygon(p) = moved else {
            panic!("a partial corner drag promotes Rect to Polygon");
        };
        // MANDATORY GEOMETRY PAIRING: corner 1 (top-right) really moved.
        assert_eq!(p.points[1], (105.0, 7.0));
        assert_eq!(p.points[0], (0.0, 0.0));
        assert_eq!(p.fill_gradient, r.fill_gradient,
                   "the fill gradient has a Polygon counterpart — it must ride");
        assert_eq!(p.stroke_gradient, r.stroke_gradient,
                   "the stroke gradient has a Polygon counterpart");
    }

    /// The rest of the Theseus list at the same site, so a future edit
    /// cannot quietly drop a field the `..` spread was never given.
    #[test]
    fn rect_corner_drag_preserves_identity_and_appearance() {
        let r = rich_rect(0.0, 0.0);
        assert_rect_fixture_is_rich(&r);
        let moved = move_control_points(
            &Element::Rect(r.clone()), &cp(2), 1.0, 1.0);
        let Element::Polygon(p) = moved else { panic!("expected Polygon") };
        assert_eq!(p.points[2], (101.0, 61.0), "corner 2 moved");
        assert_eq!(p.common.id.as_deref(), Some("rect-id"),
                   "a 1->1 kind change preserves identity");
        assert_eq!(p.common.name.as_deref(), Some("hull"));
        assert_eq!(p.common.opacity, 0.5);
        assert_eq!(p.common.mode, BlendMode::Multiply);
        assert_eq!(p.common.visibility, Visibility::Outline);
        assert_eq!(p.common.tool_origin.as_deref(), Some("blob_brush"));
        assert_eq!(p.common.transform, r.common.transform);
        assert_eq!(p.fill, r.fill);
        assert_eq!(p.stroke, r.stroke);
    }

    /// A square-cornered rect must promote to EXACTLY the four corners it
    /// always did — the flatten below is additive, not a re-shaping of the
    /// commonest case.
    #[test]
    fn square_rect_corner_drag_still_emits_exactly_four_points() {
        let r = rich_rect(0.0, 0.0);
        let moved = move_control_points(
            &Element::Rect(r), &cp(0), 2.0, 3.0);
        let Element::Polygon(p) = moved else { panic!("expected Polygon") };
        assert_eq!(p.points, vec![
            (2.0, 3.0), (100.0, 0.0), (100.0, 60.0), (0.0, 60.0),
        ]);
    }

    /// RATIFIED ANSWER (3): FLATTEN the rounding into the emitted points.
    /// `rx`/`ry` have no counterpart on Polygon (T2 shape 4), and the ruling
    /// is WYSIWYG at promotion — the corner arcs become real points instead
    /// of the rounding silently vanishing.
    #[test]
    fn rounded_rect_corner_drag_flattens_the_rounding_into_points() {
        let r = rich_rect(20.0, 10.0);
        assert_rect_fixture_is_rich(&r);
        let moved = move_control_points(
            &Element::Rect(r), &cp(1), 0.0, 0.0);
        let Element::Polygon(p) = moved else { panic!("expected Polygon") };
        assert!(p.points.len() > 4,
                "the rounding must survive as points, not evaporate; got {} \
                 points", p.points.len());
        // The square corner is GONE and the arc's feet — where the rounding
        // meets the edges — are present, at every corner.
        for sharp in [(0.0, 0.0), (100.0, 0.0), (100.0, 60.0), (0.0, 60.0)] {
            assert!(!p.points.contains(&sharp),
                    "the square corner {sharp:?} was emitted — the promotion \
                     is drawing a corner the artist did not see");
        }
        for foot in [(0.0, 10.0), (20.0, 0.0), (80.0, 0.0), (100.0, 10.0),
                     (100.0, 50.0), (80.0, 60.0), (20.0, 60.0), (0.0, 50.0)] {
            assert!(p.points.contains(&foot),
                    "the rounding's foot at {foot:?} is missing from the \
                     emitted outline");
        }
        // Every emitted point stays inside the rect the artist drew.
        assert!(p.points.iter().all(|&(x, y)|
                    (-1e-9..=100.0 + 1e-9).contains(&x)
                    && (-1e-9..=60.0 + 1e-9).contains(&y)),
                "the flatten pushed a point outside the rect");
        // The flattened outline still spans the full rect.
        let min_x = p.points.iter().map(|q| q.0).fold(f64::MAX, f64::min);
        let max_x = p.points.iter().map(|q| q.0).fold(f64::MIN, f64::max);
        assert!((min_x - 0.0).abs() < 1e-9 && (max_x - 100.0).abs() < 1e-9,
                "flattened outline spans [0..100], got [{min_x}..{max_x}]");
    }

    /// The flatten must still MOVE the dragged corner: every point of that
    /// corner's arc translates by the delta, and no other corner's does.
    #[test]
    fn rounded_rect_corner_drag_moves_the_whole_dragged_corner_arc() {
        let r = rich_rect(20.0, 10.0);
        let rest = move_control_points(
            &Element::Rect(r.clone()), &cp(1), 0.0, 0.0);
        let moved = move_control_points(
            &Element::Rect(r), &cp(1), 30.0, -40.0);
        let (Element::Polygon(a), Element::Polygon(b)) = (rest, moved) else {
            panic!("expected Polygons")
        };
        assert_eq!(a.points.len(), b.points.len());
        let n = a.points.len() / 4;
        assert!(n > 1, "each corner should contribute an arc run");
        for i in 0..a.points.len() {
            let corner = i / n;
            let (dx, dy) = (b.points[i].0 - a.points[i].0,
                            b.points[i].1 - a.points[i].1);
            if corner == 1 {
                assert!((dx - 30.0).abs() < 1e-9 && (dy + 40.0).abs() < 1e-9,
                        "point {i} of the dragged corner did not move");
            } else {
                assert!(dx.abs() < 1e-9 && dy.abs() < 1e-9,
                        "point {i} of an undragged corner moved");
            }
        }
    }

    /// A whole-element (`All`) move on a rounded rect must STAY a Rect and
    /// keep `rx`/`ry` — the flatten belongs to the promotion only.
    #[test]
    fn rounded_rect_whole_move_stays_a_rect_with_its_rounding() {
        let r = rich_rect(20.0, 10.0);
        let moved = move_control_points(&Element::Rect(r), &SelectionKind::All, 5.0, 5.0);
        let Element::Rect(out) = moved else { panic!("expected Rect") };
        assert_eq!((out.x, out.y), (5.0, 5.0));
        assert_eq!((out.rx, out.ry), (20.0, 10.0));
    }

    /// The corner runs are the machine-readable answer to "which emitted
    /// points belong to corner i" — the mapping `Controller::move_selection`
    /// needs to keep a multi-sample drag on the corner it started on.
    /// `aabb_through` is the one carrier of "a bbox through a transform"
    /// (Properties panel AND the A6 §3.3 mask bbox). The rotation arm is the
    /// contract's discriminating case: the box of the transformed corners,
    /// never the transformed box as a region.
    #[test]
    fn aabb_through_boxes_the_transformed_corners() {
        let b = (4.0, 0.0, 8.0, 8.0);
        let id = Transform { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 0.0, f: 0.0 };
        assert_eq!(aabb_through(b, &id), b);

        let shift = Transform { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 4.0, f: -1.0 };
        assert_eq!(aabb_through(b, &shift), (8.0, -1.0, 8.0, 8.0));

        // 45° about the box's own centre (8,4): the corners land 4√2 out along
        // the axes, so the AABB is the diamond's box, centred where it was.
        let s = std::f64::consts::FRAC_1_SQRT_2;
        let rot = Transform { a: s, b: s, c: -s, d: s, e: 8.0 - 4.0 * s, f: 4.0 - 12.0 * s };
        let (x, y, w, h) = aabb_through(b, &rot);
        let r = 8.0 * s; // 4√2
        for (got, want) in [(x, 8.0 - r), (y, 4.0 - r), (w, 2.0 * r), (h, 2.0 * r)] {
            assert!((got - want).abs() < 1e-9, "expected the diamond's box, got \
                     ({x}, {y}, {w}, {h})");
        }
    }

    #[test]
    fn corner_runs_are_four_equal_runs_in_cp_order() {
        let square = rounded_rect_corner_runs(0.0, 0.0, 100.0, 60.0, 0.0, 0.0);
        assert_eq!(square.iter().map(Vec::len).collect::<Vec<_>>(), vec![1, 1, 1, 1]);
        assert_eq!(square[0][0], (0.0, 0.0));
        assert_eq!(square[1][0], (100.0, 0.0));
        assert_eq!(square[2][0], (100.0, 60.0));
        assert_eq!(square[3][0], (0.0, 60.0));

        let round = rounded_rect_corner_runs(0.0, 0.0, 100.0, 60.0, 20.0, 10.0);
        let lens: Vec<usize> = round.iter().map(Vec::len).collect();
        assert!(lens.iter().all(|&l| l == lens[0] && l > 1),
                "every corner arc must sample the same number of points, got \
                 {lens:?}");
        // Each run starts and ends on the rect's edges, at the arc's feet.
        assert_eq!(round[0].first().copied(), Some((0.0, 10.0)));
        assert_eq!(round[0].last().copied(), Some((20.0, 0.0)));
        assert_eq!(round[2].first().copied(), Some((100.0, 50.0)));
        assert_eq!(round[2].last().copied(), Some((80.0, 60.0)));
    }
    /// P1.7, RULED 2026-08-21 council: **bounds follow `stroke.align`** --
    /// Center inflates by w/2 on each side, Inside not at all, Outside by w.
    ///
    /// Both active ports inflated by w/2 REGARDLESS of alignment, which is
    /// exactly right for Center and wrong for the other two -- and wrong
    /// IDENTICALLY, so the cross-language equivalence law could not see it. A
    /// shared defect is invisible to every differential gate this project owns.
    ///
    /// The figures are the board's own table, kept verbatim so the fix is
    /// checked against the measurement that found it rather than against
    /// itself.
    ///
    /// NO CLOSEDNESS BRANCH, and that is deliberate. `workspace/actions.yaml`
    /// says "Inside and outside behave as center on open paths", but no
    /// renderer implements that sentence: `canvas/render.rs::stroke_aligned`
    /// draws Inside by CLIPPING to the path's fill area at 2x width, and canvas
    /// implicitly closes an open path for clipping, so an open path's ink is
    /// clipped the same way a closed one's is. Bounds are a claim about where
    /// the ink is, so they follow the ink. The stale sentence is flagged for a
    /// ruling of its own rather than silently honoured here.
    #[test]
    fn bounds_follow_stroke_alignment() {
        fn rect_with(align: StrokeAlign) -> Element {
            let mut stroke = Stroke::new(Color::BLACK, 10.0);
            stroke.align = align;
            Element::Rect(RectElem {
                x: 10.0, y: 20.0, width: 100.0, height: 50.0, rx: 0.0, ry: 0.0,
                fill: None,
                stroke: Some(stroke),
                common: CommonProps::default(),
                fill_gradient: None,
                stroke_gradient: None,
            })
        }
        assert_eq!(rect_with(StrokeAlign::Center).bounds(), (5.0, 15.0, 110.0, 60.0),
                   "Center: the stroke straddles the path, so w/2 on each side");
        assert_eq!(rect_with(StrokeAlign::Inside).bounds(), (10.0, 20.0, 100.0, 50.0),
                   "Inside: the ink never leaves the path, so no inflation at all");
        assert_eq!(rect_with(StrokeAlign::Outside).bounds(), (0.0, 10.0, 120.0, 70.0),
                   "Outside: the whole width lies outside, so w on each side");

        // `geometric_bounds` is the ink-free box and does not move: it was the
        // honest answer all along, and Inside's preview bounds now agree with
        // it because an Inside stroke covers exactly the path.
        assert_eq!(rect_with(StrokeAlign::Inside).geometric_bounds(),
                   (10.0, 20.0, 100.0, 50.0),
                   "geometric_bounds is unchanged by this ruling");
        assert_eq!(rect_with(StrokeAlign::Inside).bounds(),
                   rect_with(StrokeAlign::Inside).geometric_bounds(),
                   "an Inside stroke adds no ink outside the path, so preview \
                    and geometric bounds coincide");
    }

    /// SUPERSEDED, and recorded rather than deleted.
    ///
    /// `preview_bounds_ignore_stroke_align_pending_a_ruling` lived here from
    /// the 2026-08-05 measurement until the 2026-08-21 council. It pinned the
    /// WRONG behaviour on purpose -- Inside and Outside both answering the
    /// Center box -- so that changing it had to be a decision instead of an
    /// accident, and its own comment said: "If the ruling lands, this test is
    /// the thing that reds."
    ///
    /// The ruling landed and it did red, which is the whole reason to write a
    /// test that way. Its content is folded into
    /// `bounds_follow_stroke_alignment` above; this note is what remains so a
    /// reader of the history does not think the pin was lost.
    #[test]
    fn the_pending_ruling_pin_was_retired_by_the_2026_08_21_council() {
        // The behaviour it pinned is now false, which is the assertion.
        let mut s = Stroke::new(Color::BLACK, 10.0);
        s.align = StrokeAlign::Inside;
        let inside = Element::Rect(RectElem {
            x: 10.0, y: 20.0, width: 100.0, height: 50.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: Some(s), common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        let mut c = Stroke::new(Color::BLACK, 10.0);
        c.align = StrokeAlign::Center;
        let center = Element::Rect(RectElem {
            x: 10.0, y: 20.0, width: 100.0, height: 50.0, rx: 0.0, ry: 0.0,
            fill: None, stroke: Some(c), common: CommonProps::default(),
            fill_gradient: None, stroke_gradient: None,
        });
        assert_ne!(inside.bounds(), center.bounds(),
                   "Inside no longer answers the Center box -- that is the ruling");
    }

}
