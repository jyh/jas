//! JSON → typed `Painter` arguments for a recorded scene.
//!
//! Pure decoding: no painter, no backend, no capability judgement. It exists so
//! more than one backend can be driven by THE SAME ARTIFACT without each one
//! growing its own reader of the same schema.
//!
//! ⚠️ KNOWN DUPLICATION, NAMED RATHER THAN HIDDEN. `direct2d/replay.rs` still
//! carries its own private copies of these functions. They are not unified yet
//! for one honest reason: that module is Windows- and `d2d`-gated and CANNOT BE
//! COMPILED on this machine, so folding it onto these would be an unverifiable
//! edit to a lane whose only instrument is CI — and it would have collided with
//! an in-flight PR touching the same file. The two copies decode one fixed
//! schema, and any drift surfaces as a replay mismatch rather than silently.
//! ⇒ COLLAPSE THEM when someone can build that lane, or when the routing
//!   question settles and the dispatch itself unifies.

use serde_json::Value;

use super::{
    Brush, ColorStop, EllipseArc, FillRule, LinearGradient, LineCap, LineJoin, PathCommand,
    RadialGradient, Rect, StrokeStyle,
};
use crate::geometry::element::{BlendMode, Color, Transform};

pub(crate) fn f(v: &Value, k: &str) -> f64 {
    v.get(k).and_then(Value::as_f64).unwrap_or(0.0)
}

pub(crate) fn color(v: &Value) -> Color {
    // Only the rgb space appears in the corpus; anything else would be a new
    // recording feature and should be NOTICED, not coerced.
    Color::new(f(v, "r"), f(v, "g"), f(v, "b"), f(v, "a"))
}

fn stops(v: &Value) -> Vec<ColorStop> {
    v.get("stops").and_then(Value::as_array).map(|a| {
        a.iter().map(|s| ColorStop {
            offset: f(s, "offset"),
            color: color(s.get("color").unwrap_or(&Value::Null)),
        }).collect()
    }).unwrap_or_default()
}

pub(crate) fn brush(v: &Value) -> Option<Brush> {
    match v.get("kind").and_then(Value::as_str)? {
        "solid" => Some(Brush::Solid(color(v.get("color")?))),
        "linear" => {
            let g = v.get("gradient")?;
            Some(Brush::Linear(LinearGradient {
                x0: f(g, "x0"), y0: f(g, "y0"), x1: f(g, "x1"), y1: f(g, "y1"),
                stops: stops(g),
            }))
        }
        "radial" => {
            let g = v.get("gradient")?;
            Some(Brush::Radial(RadialGradient {
                x0: f(g, "x0"), y0: f(g, "y0"), r0: f(g, "r0"),
                x1: f(g, "x1"), y1: f(g, "y1"), r1: f(g, "r1"),
                stops: stops(g),
            }))
        }
        _ => None,
    }
}

pub(crate) fn winding(v: &Value) -> FillRule {
    match v.get("winding").and_then(Value::as_str) {
        Some("evenodd") => FillRule::EvenOdd,
        _ => FillRule::NonZero,
    }
}

pub(crate) fn stroke(v: &Value) -> StrokeStyle {
    StrokeStyle {
        width: f(v, "width"),
        cap: match v.get("cap").and_then(Value::as_str) {
            Some("round") => LineCap::Round,
            Some("square") => LineCap::Square,
            _ => LineCap::Butt,
        },
        join: match v.get("join").and_then(Value::as_str) {
            Some("round") => LineJoin::Round,
            Some("bevel") => LineJoin::Bevel,
            _ => LineJoin::Miter,
        },
        miter: f(v, "miter"),
        dash: v.get("dash").and_then(Value::as_array)
            .map(|a| a.iter().filter_map(Value::as_f64).collect())
            .unwrap_or_default(),
    }
}

pub(crate) fn path(v: &Value) -> Vec<PathCommand> {
    v.as_array().map(|a| a.iter().filter_map(|c| {
        Some(match c.get("op").and_then(Value::as_str)? {
            "M" => PathCommand::MoveTo { x: f(c, "x"), y: f(c, "y") },
            "L" => PathCommand::LineTo { x: f(c, "x"), y: f(c, "y") },
            "C" => PathCommand::CurveTo {
                x1: f(c, "x1"), y1: f(c, "y1"), x2: f(c, "x2"), y2: f(c, "y2"),
                x: f(c, "x"), y: f(c, "y"),
            },
            "Q" => PathCommand::QuadTo {
                x1: f(c, "x1"), y1: f(c, "y1"), x: f(c, "x"), y: f(c, "y"),
            },
            "Z" => PathCommand::ClosePath,
            _ => return None,
        })
    }).collect()).unwrap_or_default()
}

pub(crate) fn arc(v: &Value) -> EllipseArc {
    EllipseArc {
        cx: f(v, "cx"), cy: f(v, "cy"), rx: f(v, "rx"), ry: f(v, "ry"),
        rotation: f(v, "rotation"), start: f(v, "start"), end: f(v, "end"),
        ccw: v.get("ccw").and_then(Value::as_bool).unwrap_or(false),
    }
}

pub(crate) fn rect(v: &Value) -> Rect {
    Rect { x: f(v, "x"), y: f(v, "y"), w: f(v, "w"), h: f(v, "h") }
}

pub(crate) fn transform(v: &Value) -> Transform {
    Transform { a: f(v, "a"), b: f(v, "b"), c: f(v, "c"), d: f(v, "d"), e: f(v, "e"), f: f(v, "f") }
}

pub(crate) fn blend(v: &Value) -> Option<BlendMode> {
    Some(match v.get("blend").and_then(Value::as_str).unwrap_or("normal") {
        "normal" => BlendMode::Normal,
        "multiply" => BlendMode::Multiply,
        "screen" => BlendMode::Screen,
        "overlay" => BlendMode::Overlay,
        "darken" => BlendMode::Darken,
        "lighten" => BlendMode::Lighten,
        "color-dodge" => BlendMode::ColorDodge,
        "color-burn" => BlendMode::ColorBurn,
        "hard-light" => BlendMode::HardLight,
        "soft-light" => BlendMode::SoftLight,
        "difference" => BlendMode::Difference,
        "exclusion" => BlendMode::Exclusion,
        "hue" => BlendMode::Hue,
        "saturation" => BlendMode::Saturation,
        "color" => BlendMode::Color,
        "luminosity" => BlendMode::Luminosity,
        // An unrecognised mode is NOT coerced to Normal: that would replay a
        // scene the corpus does not describe and report it as a clean run.
        _ => return None,
    })
}

pub(crate) fn mask(v: &Value) -> Option<super::Mask> {
    let m = v.get("mask")?;
    Some(match m.get("kind").and_then(Value::as_str)? {
        "luminance_clip_in" => super::Mask::LuminanceClipIn,
        "alpha_clip_out" => super::Mask::AlphaClipOut,
        "alpha_reveal_outside_bbox" => super::Mask::AlphaRevealOutsideBbox {
            bbox: rect(m.get("bbox").unwrap_or(&Value::Null)),
        },
        _ => return None,
    })
}
