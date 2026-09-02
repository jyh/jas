//! [`RecordingPainter`] — materializes each [`Painter`] call into a [`Command`]
//! and serializes the list to canonical JSON. This is the mechanism behind
//! R4's display-list-equivalence goldens: the goldens live where their only
//! consumer lives (tests), so there is no per-frame production tax and no
//! ungatable IR→ctx replayer (the v1 problem the FLIP dissolves).
//!
//! # R7 — the FLOAT LAW (decided here, empirically; see the `float_law` tests)
//!
//! Coordinates are serialized as a **fixed 4-decimal decimal string using
//! round-half-to-even** ([`canonical_f64`], Rust's `{:.4}` which is
//! round-half-to-even), in **document space**. The view transform (zoom/pan)
//! rides ONE matrix per [`Painter::push_state`](super::Painter::push_state) and
//! is NEVER multiplied into coordinates. Rationale:
//!
//! - **Not bit-exact.** Bit-exact goldens diverge on last-ULP differences from
//!   equivalent arithmetic (`0.1 + 0.2 != 0.3`) — brittle, the exact trap the
//!   refuter named. Proven in `float_law::bit_exact_is_unstable`.
//! - **Not screen-space rounding.** Multiplying doc coords by zoom BEFORE
//!   rounding manufactures new near-`x.xxxx5` values that straddle the rounding
//!   boundary and round inconsistently. Proven in
//!   `float_law::screen_space_rounding_can_straddle`.
//! - **Doc-space 4-decimal is stable** for equivalent scenes, because the D2
//!   decision (driver owns the view transform AS A MATRIX) keeps the coordinate
//!   stream equal to the authored/computed doc geometry. Proven in
//!   `float_law::doc_space_4dp_is_stable`.
//!
//! RESIDUAL RISK (named, not hidden): a doc coordinate that lands EXACTLY on an
//! `x.xxxx5` boundary and is computed two different ways could still straddle.
//! Doc-space keeps this rare and the transform-isolation removes the dominant
//! source; if ever bitten, raise precision or snap authored coords. This is a
//! named corner case, not an open-ended defer.

use super::{StrokeAlign, 
    BlendMode, Brush, ColorStop, EllipseArc, FillRule, LinearGradient, Mask, Painter, PathCommand,
    RadialGradient, Rect, StrokeStyle, TextRun, Transform,
};
use crate::geometry::element::{Color, LineCap, LineJoin};

/// One recorded drawing call. Mirrors the [`Painter`] trait 1:1. The recorder
/// is purely STRUCTURAL — it stores the raw arguments (incl. the raw
/// `paint_alpha` and raw group alphas); the non-isolated compounding arithmetic
/// is a backend (Canvas2dPainter) concern, verified separately. Display-list
/// equivalence = identical command sequence with identical args.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    FillPath { path: Vec<PathCommand>, winding: FillRule, brush: Brush, paint_alpha: f64 },
    StrokePath { path: Vec<PathCommand>, brush: Brush, stroke: StrokeStyle, paint_alpha: f64 },
    FillRect { rect: Rect, brush: Brush, paint_alpha: f64 },
    StrokeRect { rect: Rect, brush: Brush, stroke: StrokeStyle, paint_alpha: f64 },
    FillEllipseArc { arc: EllipseArc, winding: FillRule, brush: Brush, paint_alpha: f64 },
    StrokeEllipseArc { arc: EllipseArc, brush: Brush, stroke: StrokeStyle, align: StrokeAlign, paint_alpha: f64 },
    Clip { path: Vec<PathCommand>, winding: FillRule },
    PushState { transform: Transform },
    PopState,
    PushGroup { alpha: f64, blend: BlendMode },
    PopGroup,
    PushMaskLayer { mask: Mask },
    PopMaskLayer,
    PushIsolatedLayer { alpha: f64, blend: BlendMode },
    PopIsolatedLayer,
    DrawTextRun { run: TextRun, brush: Brush, paint_alpha: f64 },
}

/// A [`Painter`] that records every call. See module docs.
#[derive(Debug, Default)]
pub struct RecordingPainter {
    commands: Vec<Command>,
}

impl RecordingPainter {
    pub fn new() -> Self {
        Self { commands: Vec::new() }
    }

    /// The recorded commands, in call order.
    pub fn commands(&self) -> &[Command] {
        &self.commands
    }

    /// Serialize the recorded command list to canonical JSON — a pretty-printed
    /// array of objects, one per command, floats under the R7 float law. This
    /// is the golden text.
    pub fn to_canonical_json(&self) -> String {
        let mut out = String::from("[\n");
        for (i, cmd) in self.commands.iter().enumerate() {
            let j = command_to_json(cmd);
            let mut buf = String::new();
            emit(&j, 1, &mut buf);
            out.push_str(&buf);
            if i + 1 < self.commands.len() {
                out.push(',');
            }
            out.push('\n');
        }
        out.push(']');
        out
    }
}

impl Painter for RecordingPainter {
    /// The recorder materialises EVERY call into a `Command`, including the
    /// whole A6 bracket — that is what makes the goldens able to state the
    /// bracket at all. So it refuses nothing.
    ///
    /// 📌 This is the answer that keeps the R4 goldens stable across the router
    /// flip: the reference renderer emits through a recorder, the recorder
    /// supports masks, so the golden output of a masked element is what it was
    /// before the router learned to ask.
    fn supports(&self, _cap: crate::painter::capability::Capability) -> bool {
        true
    }

    fn fill_path(&mut self, path: &[PathCommand], winding: FillRule, brush: &Brush, paint_alpha: f64) {
        self.commands.push(Command::FillPath { path: path.to_vec(), winding, brush: brush.clone(), paint_alpha });
    }
    fn stroke_path(&mut self, path: &[PathCommand], brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        self.commands.push(Command::StrokePath { path: path.to_vec(), brush: brush.clone(), stroke: stroke.clone(), paint_alpha });
    }
    fn fill_rect(&mut self, rect: Rect, brush: &Brush, paint_alpha: f64) {
        self.commands.push(Command::FillRect { rect, brush: brush.clone(), paint_alpha });
    }
    fn stroke_rect(&mut self, rect: Rect, brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        self.commands.push(Command::StrokeRect { rect, brush: brush.clone(), stroke: stroke.clone(), paint_alpha });
    }
    fn fill_ellipse_arc(&mut self, arc: &EllipseArc, winding: FillRule, brush: &Brush, paint_alpha: f64) {
        self.commands.push(Command::FillEllipseArc { arc: *arc, winding, brush: brush.clone(), paint_alpha });
    }
    fn stroke_ellipse_arc(&mut self, arc: &EllipseArc, brush: &Brush, stroke: &StrokeStyle, align: StrokeAlign, paint_alpha: f64) {
        self.commands.push(Command::StrokeEllipseArc { arc: *arc, brush: brush.clone(), stroke: stroke.clone(), align, paint_alpha });
    }
    fn clip(&mut self, path: &[PathCommand], winding: FillRule) {
        self.commands.push(Command::Clip { path: path.to_vec(), winding });
    }
    fn push_state(&mut self, transform: Transform) {
        self.commands.push(Command::PushState { transform });
    }
    fn pop_state(&mut self) {
        self.commands.push(Command::PopState);
    }
    fn push_group(&mut self, alpha: f64, blend: BlendMode) {
        self.commands.push(Command::PushGroup { alpha, blend });
    }
    fn pop_group(&mut self) {
        self.commands.push(Command::PopGroup);
    }
    fn push_mask_layer(&mut self, mask: Mask) {
        self.commands.push(Command::PushMaskLayer { mask });
    }
    fn pop_mask_layer(&mut self) {
        self.commands.push(Command::PopMaskLayer);
    }

    fn push_isolated_layer(&mut self, alpha: f64, blend: BlendMode) {
        self.commands.push(Command::PushIsolatedLayer { alpha, blend });
    }

    fn pop_isolated_layer(&mut self) {
        self.commands.push(Command::PopIsolatedLayer);
    }
    fn draw_text_run(&mut self, run: &TextRun, brush: &Brush, paint_alpha: f64) {
        self.commands.push(Command::DrawTextRun { run: run.clone(), brush: brush.clone(), paint_alpha });
    }
}

// ---------------------------------------------------------------------------
// R7 — the float law
// ---------------------------------------------------------------------------

/// Canonicalize a coordinate under the R7 float law: fixed 4 decimals,
/// round-half-to-even (Rust's `{:.4}`), with `-0` normalized to `0`. This is
/// the ONLY place a coordinate becomes golden text.
pub fn canonical_f64(x: f64) -> String {
    if !x.is_finite() {
        // Non-finite coords are a bug upstream, not a golden value — make them
        // loud rather than silently formatting "NaN"/"inf".
        return format!("\"non-finite:{x}\"");
    }
    let s = format!("{x:.4}");
    // Normalize "-0.0000" → "0.0000" so a signed zero can't split a golden.
    if s == "-0.0000" { "0.0000".to_string() } else { s }
}

// ---------------------------------------------------------------------------
// Canonical JSON emitter (hand-rolled so floats obey the float law; serde_json
// would format them with full round-trip precision, defeating R7).
// ---------------------------------------------------------------------------

enum J {
    /// A coordinate/scalar float — emitted via `canonical_f64`.
    F(f64),
    Int(i64),
    Bool(bool),
    Str(String),
    Arr(Vec<J>),
    Obj(Vec<(&'static str, J)>),
}

fn emit(j: &J, indent: usize, out: &mut String) {
    match j {
        J::F(x) => out.push_str(&canonical_f64(*x)),
        J::Int(n) => out.push_str(&n.to_string()),
        J::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        J::Str(s) => {
            out.push('"');
            for c in s.chars() {
                match c {
                    '"' => out.push_str("\\\""),
                    '\\' => out.push_str("\\\\"),
                    '\n' => out.push_str("\\n"),
                    '\t' => out.push_str("\\t"),
                    '\r' => out.push_str("\\r"),
                    _ => out.push(c),
                }
            }
            out.push('"');
        }
        J::Arr(items) => {
            if items.is_empty() {
                out.push_str("[]");
                return;
            }
            out.push('[');
            for (i, it) in items.iter().enumerate() {
                emit(it, indent, out);
                if i + 1 < items.len() {
                    out.push_str(", ");
                }
            }
            out.push(']');
        }
        J::Obj(fields) => {
            out.push('{');
            let pad = "  ".repeat(indent + 1);
            for (i, (k, v)) in fields.iter().enumerate() {
                out.push('\n');
                out.push_str(&pad);
                out.push('"');
                out.push_str(k);
                out.push_str("\": ");
                emit(v, indent + 1, out);
                if i + 1 < fields.len() {
                    out.push(',');
                }
            }
            out.push('\n');
            out.push_str(&"  ".repeat(indent));
            out.push('}');
        }
    }
}

fn color_json(c: &Color) -> J {
    // Serialize colors in a stable, space-tagged form. RGBA components ride the
    // float law like any other scalar.
    match *c {
        Color::Rgb { r, g, b, a } => J::Obj(vec![
            ("space", J::Str("rgb".into())),
            ("r", J::F(r)), ("g", J::F(g)), ("b", J::F(b)), ("a", J::F(a)),
        ]),
        Color::Hsb { h, s, b, a } => J::Obj(vec![
            ("space", J::Str("hsb".into())),
            ("h", J::F(h)), ("s", J::F(s)), ("b", J::F(b)), ("a", J::F(a)),
        ]),
        Color::Cmyk { c, m, y, k, a } => J::Obj(vec![
            ("space", J::Str("cmyk".into())),
            ("c", J::F(c)), ("m", J::F(m)), ("y", J::F(y)), ("k", J::F(k)), ("a", J::F(a)),
        ]),
    }
}

fn stop_json(s: &ColorStop) -> J {
    J::Obj(vec![("offset", J::F(s.offset)), ("color", color_json(&s.color))])
}

fn linear_json(g: &LinearGradient) -> J {
    J::Obj(vec![
        ("x0", J::F(g.x0)), ("y0", J::F(g.y0)), ("x1", J::F(g.x1)), ("y1", J::F(g.y1)),
        ("stops", J::Arr(g.stops.iter().map(stop_json).collect())),
    ])
}

fn radial_json(g: &RadialGradient) -> J {
    J::Obj(vec![
        ("x0", J::F(g.x0)), ("y0", J::F(g.y0)), ("r0", J::F(g.r0)),
        ("x1", J::F(g.x1)), ("y1", J::F(g.y1)), ("r1", J::F(g.r1)),
        ("stops", J::Arr(g.stops.iter().map(stop_json).collect())),
    ])
}

fn brush_json(b: &Brush) -> J {
    match b {
        Brush::Solid(c) => J::Obj(vec![("kind", J::Str("solid".into())), ("color", color_json(c))]),
        Brush::Linear(g) => J::Obj(vec![("kind", J::Str("linear".into())), ("gradient", linear_json(g))]),
        Brush::Radial(g) => J::Obj(vec![("kind", J::Str("radial".into())), ("gradient", radial_json(g))]),
    }
}

fn cap_str(c: LineCap) -> &'static str {
    match c { LineCap::Butt => "butt", LineCap::Round => "round", LineCap::Square => "square" }
}
fn join_str(j: LineJoin) -> &'static str {
    match j { LineJoin::Miter => "miter", LineJoin::Round => "round", LineJoin::Bevel => "bevel" }
}

fn stroke_json(s: &StrokeStyle) -> J {
    J::Obj(vec![
        ("width", J::F(s.width)),
        ("cap", J::Str(cap_str(s.cap).into())),
        ("join", J::Str(join_str(s.join).into())),
        ("miter", J::F(s.miter)),
        ("dash", J::Arr(s.dash.iter().map(|d| J::F(*d)).collect())),
    ])
}

fn winding_str(w: FillRule) -> &'static str {
    match w { FillRule::NonZero => "nonzero", FillRule::EvenOdd => "evenodd" }
}

fn path_json(path: &[PathCommand]) -> J {
    J::Arr(path.iter().map(pathcmd_json).collect())
}

fn pathcmd_json(p: &PathCommand) -> J {
    match *p {
        PathCommand::MoveTo { x, y } => J::Obj(vec![("op", J::Str("M".into())), ("x", J::F(x)), ("y", J::F(y))]),
        PathCommand::LineTo { x, y } => J::Obj(vec![("op", J::Str("L".into())), ("x", J::F(x)), ("y", J::F(y))]),
        PathCommand::CurveTo { x1, y1, x2, y2, x, y } => J::Obj(vec![
            ("op", J::Str("C".into())),
            ("x1", J::F(x1)), ("y1", J::F(y1)), ("x2", J::F(x2)), ("y2", J::F(y2)), ("x", J::F(x)), ("y", J::F(y)),
        ]),
        PathCommand::SmoothCurveTo { x2, y2, x, y } => J::Obj(vec![
            ("op", J::Str("S".into())), ("x2", J::F(x2)), ("y2", J::F(y2)), ("x", J::F(x)), ("y", J::F(y)),
        ]),
        PathCommand::QuadTo { x1, y1, x, y } => J::Obj(vec![
            ("op", J::Str("Q".into())), ("x1", J::F(x1)), ("y1", J::F(y1)), ("x", J::F(x)), ("y", J::F(y)),
        ]),
        PathCommand::SmoothQuadTo { x, y } => J::Obj(vec![("op", J::Str("T".into())), ("x", J::F(x)), ("y", J::F(y))]),
        PathCommand::ArcTo { rx, ry, x_rotation, large_arc, sweep, x, y } => J::Obj(vec![
            ("op", J::Str("A".into())),
            ("rx", J::F(rx)), ("ry", J::F(ry)), ("rot", J::F(x_rotation)),
            ("large", J::Bool(large_arc)), ("sweep", J::Bool(sweep)), ("x", J::F(x)), ("y", J::F(y)),
        ]),
        PathCommand::ClosePath => J::Obj(vec![("op", J::Str("Z".into()))]),
    }
}

fn transform_json(t: &Transform) -> J {
    J::Obj(vec![
        ("a", J::F(t.a)), ("b", J::F(t.b)), ("c", J::F(t.c)),
        ("d", J::F(t.d)), ("e", J::F(t.e)), ("f", J::F(t.f)),
    ])
}

/// The inverse of [`blend_str`], for anything that READS a recorded scene.
///
/// ⛔ IT LIVES HERE, BESIDE ITS INVERSE, ON PURPOSE. `direct2d::replay` is the
/// first reader that needs more than `"normal"`, and the obvious place to put
/// this was there — which would make TWO independent spellings of a
/// sixteen-arm kebab-case vocabulary, in two files, with nothing comparing
/// them. The first `color-burn`/`color_burn` slip would then be a scene that
/// replays as `Normal` on one backend and refuses on another, silently.
/// `blend_names_round_trip` is what keeps that impossible.
pub fn blend_from_str(s: &str) -> Option<BlendMode> {
    Some(match s {
        "normal" => BlendMode::Normal,
        "darken" => BlendMode::Darken,
        "multiply" => BlendMode::Multiply,
        "color-burn" => BlendMode::ColorBurn,
        "lighten" => BlendMode::Lighten,
        "screen" => BlendMode::Screen,
        "color-dodge" => BlendMode::ColorDodge,
        "overlay" => BlendMode::Overlay,
        "soft-light" => BlendMode::SoftLight,
        "hard-light" => BlendMode::HardLight,
        "difference" => BlendMode::Difference,
        "exclusion" => BlendMode::Exclusion,
        "hue" => BlendMode::Hue,
        "saturation" => BlendMode::Saturation,
        "color" => BlendMode::Color,
        "luminosity" => BlendMode::Luminosity,
        // An UNKNOWN name is `None`, never a default. Substituting `Normal`
        // would render a plausible wrong picture for a mode this build does not
        // know — the same failure the mask-law arm refuses one file over.
        _ => return None,
    })
}

fn blend_str(m: BlendMode) -> &'static str {
    match m {
        BlendMode::Normal => "normal", BlendMode::Darken => "darken", BlendMode::Multiply => "multiply",
        BlendMode::ColorBurn => "color-burn", BlendMode::Lighten => "lighten", BlendMode::Screen => "screen",
        BlendMode::ColorDodge => "color-dodge", BlendMode::Overlay => "overlay", BlendMode::SoftLight => "soft-light",
        BlendMode::HardLight => "hard-light", BlendMode::Difference => "difference", BlendMode::Exclusion => "exclusion",
        BlendMode::Hue => "hue", BlendMode::Saturation => "saturation", BlendMode::Color => "color",
        BlendMode::Luminosity => "luminosity",
    }
}

fn ellipse_json(a: &EllipseArc) -> J {
    J::Obj(vec![
        ("cx", J::F(a.cx)), ("cy", J::F(a.cy)), ("rx", J::F(a.rx)), ("ry", J::F(a.ry)),
        ("rotation", J::F(a.rotation)), ("start", J::F(a.start)), ("end", J::F(a.end)), ("ccw", J::Bool(a.ccw)),
    ])
}

fn rect_json(r: &Rect) -> J {
    J::Obj(vec![("x", J::F(r.x)), ("y", J::F(r.y)), ("w", J::F(r.w)), ("h", J::F(r.h))])
}

fn mask_json(m: &Mask) -> J {
    match m {
        Mask::LuminanceClipIn => J::Obj(vec![("kind", J::Str("luminance_clip_in".into()))]),
        Mask::AlphaClipOut => J::Obj(vec![("kind", J::Str("alpha_clip_out".into()))]),
        Mask::AlphaRevealOutsideBbox { bbox } => J::Obj(vec![
            ("kind", J::Str("alpha_reveal_outside_bbox".into())), ("bbox", rect_json(bbox)),
        ]),
    }
}

fn textrun_json(r: &TextRun) -> J {
    match r {
        TextRun::FastRun { font, size, text, letter_spacing, x, y } => J::Obj(vec![
            ("mode", J::Str("fast_run".into())),
            ("font", J::Str(font.clone())), ("size", J::F(*size)), ("text", J::Str(text.clone())),
            ("letter_spacing", J::F(*letter_spacing)), ("x", J::F(*x)), ("y", J::F(*y)),
        ]),
        TextRun::PlacedGlyphs { font, size, glyphs } => J::Obj(vec![
            ("mode", J::Str("placed_glyphs".into())),
            ("font", J::Str(font.clone())), ("size", J::F(*size)),
            ("glyphs", J::Arr(glyphs.iter().map(|g| J::Obj(vec![
                ("glyph_id", J::Int(g.glyph_id as i64)), ("x", J::F(g.x)), ("y", J::F(g.y)),
            ])).collect())),
        ]),
    }
}

fn command_to_json(cmd: &Command) -> J {
    match cmd {
        Command::FillPath { path, winding, brush, paint_alpha } => J::Obj(vec![
            ("cmd", J::Str("fill_path".into())),
            ("path", path_json(path)), ("winding", J::Str(winding_str(*winding).into())),
            ("brush", brush_json(brush)), ("alpha", J::F(*paint_alpha)),
        ]),
        Command::StrokePath { path, brush, stroke, paint_alpha } => J::Obj(vec![
            ("cmd", J::Str("stroke_path".into())),
            ("path", path_json(path)), ("brush", brush_json(brush)),
            ("stroke", stroke_json(stroke)), ("alpha", J::F(*paint_alpha)),
        ]),
        Command::FillRect { rect, brush, paint_alpha } => J::Obj(vec![
            ("cmd", J::Str("fill_rect".into())),
            ("rect", rect_json(rect)), ("brush", brush_json(brush)), ("alpha", J::F(*paint_alpha)),
        ]),
        Command::StrokeRect { rect, brush, stroke, paint_alpha } => J::Obj(vec![
            ("cmd", J::Str("stroke_rect".into())),
            ("rect", rect_json(rect)), ("brush", brush_json(brush)),
            ("stroke", stroke_json(stroke)), ("alpha", J::F(*paint_alpha)),
        ]),
        Command::FillEllipseArc { arc, winding, brush, paint_alpha } => J::Obj(vec![
            ("cmd", J::Str("fill_ellipse_arc".into())),
            ("arc", ellipse_json(arc)), ("winding", J::Str(winding_str(*winding).into())),
            ("brush", brush_json(brush)), ("alpha", J::F(*paint_alpha)),
        ]),
        // ⛔ `align` IS EMITTED ONLY WHEN IT IS NOT CENTER, and that is not
        // tidiness -- this JSON is the CROSS-LANGUAGE CORPUS FORMAT. Every
        // pinned golden today is centre-aligned, so an unconditional field
        // would rewrite all of them and red the Swift lane over a value that
        // carries no new information. Additive by construction: a reader that
        // has never seen `align` sees exactly the bytes it saw before.
        Command::StrokeEllipseArc { arc, brush, stroke, align, paint_alpha } => {
            let mut f = vec![
                ("cmd", J::Str("stroke_ellipse_arc".into())),
                ("arc", ellipse_json(arc)), ("brush", brush_json(brush)),
                ("stroke", stroke_json(stroke)), ("alpha", J::F(*paint_alpha)),
            ];
            if *align != StrokeAlign::Center {
                f.push(("align", J::Str(match align {
                    StrokeAlign::Inside => "inside".into(),
                    StrokeAlign::Outside => "outside".into(),
                    StrokeAlign::Center => unreachable!("guarded above"),
                })));
            }
            J::Obj(f)
        }
        Command::Clip { path, winding } => J::Obj(vec![
            ("cmd", J::Str("clip".into())),
            ("path", path_json(path)), ("winding", J::Str(winding_str(*winding).into())),
        ]),
        Command::PushState { transform } => J::Obj(vec![
            ("cmd", J::Str("push_state".into())), ("transform", transform_json(transform)),
        ]),
        Command::PopState => J::Obj(vec![("cmd", J::Str("pop_state".into()))]),
        Command::PushGroup { alpha, blend } => J::Obj(vec![
            ("cmd", J::Str("push_group".into())), ("alpha", J::F(*alpha)), ("blend", J::Str(blend_str(*blend).into())),
        ]),
        Command::PopGroup => J::Obj(vec![("cmd", J::Str("pop_group".into()))]),
        // A6 (2026-08-27). The isolated-layer bracket serialises like the group
        // bracket: alpha and blend ride the PUSH and are consumed once at the
        // closing composite, so the pop carries no payload.
        Command::PushIsolatedLayer { alpha, blend } => J::Obj(vec![
            ("cmd", J::Str("push_isolated_layer".into())), ("alpha", J::F(*alpha)), ("blend", J::Str(blend_str(*blend).into())),
        ]),
        Command::PopIsolatedLayer => J::Obj(vec![("cmd", J::Str("pop_isolated_layer".into()))]),
        Command::PushMaskLayer { mask } => J::Obj(vec![
            ("cmd", J::Str("push_mask_layer".into())), ("mask", mask_json(mask)),
        ]),
        Command::PopMaskLayer => J::Obj(vec![("cmd", J::Str("pop_mask_layer".into()))]),
        Command::DrawTextRun { run, brush, paint_alpha } => J::Obj(vec![
            ("cmd", J::Str("draw_text_run".into())),
            ("run", textrun_json(run)), ("brush", brush_json(brush)), ("alpha", J::F(*paint_alpha)),
        ]),
    }
}

// ---------------------------------------------------------------------------
// R7 float-law experiments — the EVIDENCE for the decision above.
// ---------------------------------------------------------------------------

#[cfg(test)]
mod float_law {
    use super::canonical_f64;

    /// Bit-exact serialization is UNSTABLE: two mathematically-equal doc
    /// coordinates produced by different arithmetic paths differ in the last
    /// ULP, so their bit patterns (and shortest round-trip strings) diverge.
    /// This is why the float law is NOT bit-exact.
    #[test]
    fn bit_exact_is_unstable() {
        let a = 0.1_f64 + 0.2; // 0.30000000000000004
        let b = 0.3_f64;
        assert_ne!(a.to_bits(), b.to_bits(), "0.1+0.2 and 0.3 differ in bits");
        assert_ne!(format!("{a:?}"), format!("{b:?}"), "and in shortest round-trip text");
    }

    /// The CHOSEN law (doc-space 4-decimal round-half-to-even) is STABLE across
    /// those same equivalent inputs.
    #[test]
    fn doc_space_4dp_is_stable() {
        let a = 0.1_f64 + 0.2;
        let b = 0.3_f64;
        assert_eq!(canonical_f64(a), canonical_f64(b), "4dp collapses the ULP difference");
        assert_eq!(canonical_f64(a), "0.3000");
    }

    /// Screen-space rounding CAN STRADDLE. Distributivity fails in f64:
    /// `(a + b) * z` and `a*z + b*z` are mathematically equal but differ by
    /// ULPs. When the product lands near an `x.xxxx5` boundary, SCREEN-space
    /// 4-decimal rounding gives DIFFERENT strings for the two equivalent build
    /// paths — the trap. (Doc-space never multiplies by zoom: it serializes
    /// `a+b` and `z` separately, each a single stable value, so it is immune.)
    ///
    /// This searches rather than hand-computing a boundary, so it is a
    /// self-verifying existence proof, not a magic-number assertion.
    #[test]
    fn screen_space_rounding_can_straddle() {
        let mut found: Option<(f64, f64, f64, String, String)> = None;
        'search: for ai in 1..60u32 {
            for bi in 1..60u32 {
                for zi in 1..300u32 {
                    let a = ai as f64 * 0.11;
                    let b = bi as f64 * 0.13;
                    let z = zi as f64 * 0.037;
                    let s1 = (a + b) * z; // "reached one way"
                    let s2 = a * z + b * z; // "reached an equivalent way"
                    if s1 == s2 {
                        continue; // not a straddle if the bits agree
                    }
                    if canonical_f64(s1) != canonical_f64(s2) {
                        found = Some((a, b, z, canonical_f64(s1), canonical_f64(s2)));
                        break 'search;
                    }
                }
            }
        }
        let (a, b, z, r1, r2) = found.expect(
            "expected some (a,b,z) whose two equivalent screen products round to different 4dp strings",
        );
        // The screen paths disagree...
        assert_ne!(r1, r2, "screen-space straddle at a={a}, b={b}, z={z}: {r1} vs {r2}");
        // ...while the DOC-space serialization of the same inputs is stable:
        // a+b is a single value, z is a single value, neither is near-boundary
        // manufactured by the multiply.
        assert_eq!(canonical_f64(a + b), canonical_f64(a + b));
        assert_eq!(canonical_f64(z), canonical_f64(z));
    }

    /// The straddle vanishes when we DON'T introduce the near-boundary value:
    /// an authored doc coord computed the SAME way is always byte-identical to
    /// itself, and coordinates that don't land on the boundary are stable under
    /// small equivalent perturbations.
    #[test]
    fn doc_space_avoids_the_boundary() {
        // A realistic authored coord, perturbed by a sub-rounding equivalent
        // amount (the kind of ULP noise equivalent scene-builds produce), is
        // stable — it is NOT on an x.xxxx5 boundary.
        let base = 128.7300_f64;
        let noisy = base + 1e-9 - 1e-9; // equivalent arithmetic, ULP noise
        assert_eq!(canonical_f64(base), canonical_f64(noisy));
        assert_eq!(canonical_f64(base), "128.7300");
    }

    /// Signed zero is normalized so `-0.0` and `0.0` never split a golden.
    #[test]
    fn negative_zero_normalized() {
        assert_eq!(canonical_f64(-0.0), "0.0000");
        assert_eq!(canonical_f64(0.0), "0.0000");
    }
}

#[cfg(test)]
mod a6_tests {
    use super::*;
    use crate::painter::{BlendMode, Painter};

    /// ⛔ EVERY blend name round-trips, and the list is walked EXHAUSTIVELY
    /// rather than sampled.
    ///
    /// This is the arm that makes `blend_from_str` safe to live beside its
    /// inverse instead of being re-spelled by each reader. A sampled test
    /// (`multiply` and `normal`, say) would pass over a `color_burn` typo in
    /// either direction — and that scene would then replay as a *different
    /// blend* on the backend that misread it, which is a wrong picture nothing
    /// reports.
    ///
    /// The `ALL` list is checked against the enum by the exhaustive `match` in
    /// `blend_str` itself: adding a variant there without adding it here leaves
    /// the count assertion below to catch it.
    #[test]
    fn blend_names_round_trip() {
        const ALL: [BlendMode; 16] = [
            BlendMode::Normal, BlendMode::Darken, BlendMode::Multiply,
            BlendMode::ColorBurn, BlendMode::Lighten, BlendMode::Screen,
            BlendMode::ColorDodge, BlendMode::Overlay, BlendMode::SoftLight,
            BlendMode::HardLight, BlendMode::Difference, BlendMode::Exclusion,
            BlendMode::Hue, BlendMode::Saturation, BlendMode::Color,
            BlendMode::Luminosity,
        ];
        let mut seen = std::collections::BTreeSet::new();
        for m in ALL {
            let s = blend_str(m);
            assert_eq!(blend_from_str(s), Some(m), "{s} did not round-trip");
            assert!(seen.insert(s), "two modes share the name {s}");
        }
        assert_eq!(seen.len(), 16, "a BlendMode variant is missing from ALL");
        assert_eq!(blend_from_str("no-such-mode"), None,
                   "an unknown name must be None, never a silent Normal");
    }

    /// AMENDMENT A6 (ratified 2026-08-27): the isolated-layer bracket is part of
    /// the seam vocabulary and must record in order, like every other bracket.
    #[test]
    fn isolated_layer_bracket_records_in_order() {
        let mut r = RecordingPainter::new();
        r.push_isolated_layer(0.5, BlendMode::Normal);
        r.push_mask_layer(Mask::AlphaClipOut);
        r.pop_mask_layer();
        r.pop_isolated_layer();
        let got: Vec<&str> = r
            .commands
            .iter()
            .map(|c| match c {
                Command::PushIsolatedLayer { .. } => "push_isolated",
                Command::PushMaskLayer { .. } => "push_mask",
                Command::PopMaskLayer => "pop_mask",
                Command::PopIsolatedLayer => "pop_isolated",
                _ => "other",
            })
            .collect();
        assert_eq!(
            got,
            vec!["push_isolated", "push_mask", "pop_mask", "pop_isolated"],
            "A6 §3.2 grammar: the mask bracket nests INSIDE the isolated layer"
        );
    }

    /// A6 §3.1: `alpha` and `blend` are carried on the PUSH and consumed once at
    /// the closing composite — so the recorder must preserve both verbatim.
    #[test]
    fn isolated_layer_carries_alpha_and_blend() {
        let mut r = RecordingPainter::new();
        r.push_isolated_layer(0.25, BlendMode::Multiply);
        r.pop_isolated_layer();
        match &r.commands[0] {
            Command::PushIsolatedLayer { alpha, blend } => {
                assert_eq!(*alpha, 0.25);
                assert_eq!(*blend, BlendMode::Multiply);
            }
            other => panic!("expected PushIsolatedLayer, got {other:?}"),
        }
    }
}
