//! [`Canvas2dPainter`] — the production-backend STUB. It proves the [`Painter`]
//! trait maps 1:1 onto `web_sys::CanvasRenderingContext2d` call sequences.
//!
//! SPIKE STATUS: this is COMPILE-CHECKED, not run. web-sys bindings compile on
//! any target (the native `cargo test`/`cargo build` type-checks these bodies),
//! but the methods only do anything inside a real browser, and this painter is
//! NOT wired into `canvas/render.rs` — the FLIP is unratified, so production
//! conversion is forbidden. If the council ratifies, PH1 wires this in as the
//! mechanical 1:1 rewrite of today's call sites (R4 diff discipline).
//!
//! What it demonstrates:
//! - every trait method has an obvious, allocation-light `ctx.*` lowering;
//! - the NON-ISOLATED group alpha (contract pin) is a plain multiply tracked in
//!   an owned stack — NOTHING is read back off the context (D3: the group-alpha
//!   getter dies);
//! - typed styles become CSS strings HERE and only here (R3/R5).

use super::{
    Brush, EllipseArc, FillRule, LinearGradient, Mask, Painter, PathCommand, RadialGradient, Rect,
    StrokeStyle, TextRun,
};
use crate::geometry::element::{BlendMode, Color, LineCap, LineJoin, Transform};
use wasm_bindgen::JsValue;
use web_sys::{CanvasRenderingContext2d, CanvasWindingRule};

/// A [`Painter`] that draws onto a 2D canvas context. See module docs — STUB,
/// compile-checked only in this spike.
pub struct Canvas2dPainter<'a> {
    ctx: &'a CanvasRenderingContext2d,
    /// The open group alphas. The effective paint alpha is
    /// `product(group_alpha_stack) * paint_alpha` — the non-isolated compound
    /// (contract pin). Tracked here, never read back off `ctx`.
    group_alpha_stack: Vec<f64>,
}

impl<'a> Canvas2dPainter<'a> {
    pub fn new(ctx: &'a CanvasRenderingContext2d) -> Self {
        Self { ctx, group_alpha_stack: Vec::new() }
    }

    /// Product of the open group alphas (1.0 with no group open).
    fn group_alpha(&self) -> f64 {
        self.group_alpha_stack.iter().copied().product()
    }

    /// Set `globalAlpha` to the effective compound value for a paint.
    fn apply_alpha(&self, paint_alpha: f64) {
        self.ctx.set_global_alpha(self.group_alpha() * paint_alpha);
    }

    fn set_fill_brush(&self, brush: &Brush) {
        match brush {
            Brush::Solid(c) => self.ctx.set_fill_style_str(&css_color(c)),
            Brush::Linear(g) => {
                if let Some(cg) = self.linear_gradient(g) {
                    self.ctx.set_fill_style_canvas_gradient(&cg);
                }
            }
            Brush::Radial(g) => {
                if let Some(cg) = self.radial_gradient(g) {
                    self.ctx.set_fill_style_canvas_gradient(&cg);
                }
            }
        }
    }

    fn set_stroke_brush(&self, brush: &Brush) {
        match brush {
            Brush::Solid(c) => self.ctx.set_stroke_style_str(&css_color(c)),
            Brush::Linear(g) => {
                if let Some(cg) = self.linear_gradient(g) {
                    self.ctx.set_stroke_style_canvas_gradient(&cg);
                }
            }
            Brush::Radial(g) => {
                if let Some(cg) = self.radial_gradient(g) {
                    self.ctx.set_stroke_style_canvas_gradient(&cg);
                }
            }
        }
    }

    fn linear_gradient(&self, g: &LinearGradient) -> Option<web_sys::CanvasGradient> {
        let cg = self.ctx.create_linear_gradient(g.x0, g.y0, g.x1, g.y1);
        for s in &g.stops {
            let _ = cg.add_color_stop(s.offset as f32, &css_color(&s.color));
        }
        Some(cg)
    }

    fn radial_gradient(&self, g: &RadialGradient) -> Option<web_sys::CanvasGradient> {
        let cg = self
            .ctx
            .create_radial_gradient(g.x0, g.y0, g.r0, g.x1, g.y1, g.r1)
            .ok()?;
        for s in &g.stops {
            let _ = cg.add_color_stop(s.offset as f32, &css_color(&s.color));
        }
        Some(cg)
    }

    fn apply_stroke_style(&self, s: &StrokeStyle) {
        self.ctx.set_line_width(s.width);
        self.ctx.set_line_cap(cap_str(s.cap));
        self.ctx.set_line_join(join_str(s.join));
        self.ctx.set_miter_limit(s.miter);
        let arr = js_sys::Array::new();
        for d in &s.dash {
            arr.push(&JsValue::from_f64(*d));
        }
        let _ = self.ctx.set_line_dash(&arr);
    }

    fn build_path(&self, path: &[PathCommand]) {
        self.ctx.begin_path();
        for cmd in path {
            match *cmd {
                PathCommand::MoveTo { x, y } => self.ctx.move_to(x, y),
                PathCommand::LineTo { x, y } => self.ctx.line_to(x, y),
                PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                    self.ctx.bezier_curve_to(x1, y1, x2, y2, x, y)
                }
                PathCommand::QuadTo { x1, y1, x, y } => self.ctx.quadratic_curve_to(x1, y1, x, y),
                PathCommand::ClosePath => self.ctx.close_path(),
                // SmoothCurveTo/SmoothQuadTo/ArcTo fall back to line_to, exactly
                // as today's `render::build_path` does (a known simplification
                // tracked for a later phase; preserved here for 1:1 fidelity).
                PathCommand::SmoothCurveTo { x, y, .. }
                | PathCommand::SmoothQuadTo { x, y }
                | PathCommand::ArcTo { x, y, .. } => self.ctx.line_to(x, y),
            }
        }
    }

    fn build_ellipse(&self, a: &EllipseArc) {
        self.ctx.begin_path();
        // Full circle (rx == ry, rotation 0) uses arc; the general case uses
        // ellipse. Both are the missing-circle primitive the v1 IR lacked.
        let _ = self.ctx.ellipse_with_anticlockwise(
            a.cx, a.cy, a.rx, a.ry, a.rotation, a.start, a.end, a.ccw,
        );
    }
}

fn winding(w: FillRule) -> CanvasWindingRule {
    match w {
        FillRule::NonZero => CanvasWindingRule::Nonzero,
        FillRule::EvenOdd => CanvasWindingRule::Evenodd,
    }
}

impl Painter for Canvas2dPainter<'_> {
    fn fill_path(&mut self, path: &[PathCommand], w: FillRule, brush: &Brush, paint_alpha: f64) {
        self.build_path(path);
        self.set_fill_brush(brush);
        self.apply_alpha(paint_alpha);
        self.ctx.fill_with_canvas_winding_rule(winding(w));
    }

    fn stroke_path(&mut self, path: &[PathCommand], brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        self.build_path(path);
        self.set_stroke_brush(brush);
        self.apply_stroke_style(stroke);
        self.apply_alpha(paint_alpha);
        self.ctx.stroke();
    }

    fn fill_rect(&mut self, r: Rect, brush: &Brush, paint_alpha: f64) {
        self.set_fill_brush(brush);
        self.apply_alpha(paint_alpha);
        self.ctx.fill_rect(r.x, r.y, r.w, r.h);
    }

    fn stroke_rect(&mut self, r: Rect, brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        self.set_stroke_brush(brush);
        self.apply_stroke_style(stroke);
        self.apply_alpha(paint_alpha);
        self.ctx.stroke_rect(r.x, r.y, r.w, r.h);
    }

    fn fill_ellipse_arc(&mut self, arc: &EllipseArc, w: FillRule, brush: &Brush, paint_alpha: f64) {
        self.build_ellipse(arc);
        self.set_fill_brush(brush);
        self.apply_alpha(paint_alpha);
        self.ctx.fill_with_canvas_winding_rule(winding(w));
    }

    fn stroke_ellipse_arc(&mut self, arc: &EllipseArc, brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        self.build_ellipse(arc);
        self.set_stroke_brush(brush);
        self.apply_stroke_style(stroke);
        self.apply_alpha(paint_alpha);
        self.ctx.stroke();
    }

    fn clip(&mut self, path: &[PathCommand], w: FillRule) {
        self.build_path(path);
        self.ctx.clip_with_canvas_winding_rule(winding(w));
    }

    fn push_state(&mut self, transform: Transform) {
        self.ctx.save();
        let _ = self.ctx.transform(
            transform.a, transform.b, transform.c, transform.d, transform.e, transform.f,
        );
    }

    fn pop_state(&mut self) {
        self.ctx.restore();
    }

    fn push_group(&mut self, alpha: f64, blend: BlendMode) {
        // save() scopes the composite op so pop_group restores the parent's
        // without a read-back. The alpha is a plain multiply on our own stack
        // (non-isolated compound — the contract pin).
        self.ctx.save();
        let _ = self.ctx.set_global_composite_operation(blend_css(blend));
        self.group_alpha_stack.push(alpha);
    }

    fn pop_group(&mut self) {
        self.group_alpha_stack.pop();
        self.ctx.restore();
    }

    fn push_mask_layer(&mut self, _mask: Mask) {
        // DEFERRED — PH4 owns the scratch-offscreen pipeline. Present so the
        // trait object is complete; unreachable in this spike.
        unimplemented!("mask layers are PH4 (deferred in the PH1 spike)");
    }

    fn pop_mask_layer(&mut self) {
        unimplemented!("mask layers are PH4 (deferred in the PH1 spike)");
    }

    fn draw_text_run(&mut self, run: &TextRun, brush: &Brush, paint_alpha: f64) {
        self.set_fill_brush(brush);
        self.apply_alpha(paint_alpha);
        match run {
            TextRun::FastRun { font, size, text, letter_spacing, x, y } => {
                self.ctx.set_font(&format!("{size}px {font}"));
                // native letterSpacing is set via a CSS property on the ctx (a
                // Reflect set in today's code); elided in the stub — the point
                // proven here is the single fill_text at the baseline anchor.
                let _ = *letter_spacing;
                let _ = self.ctx.fill_text(text, *x, *y);
            }
            TextRun::PlacedGlyphs { font, size, glyphs } => {
                self.ctx.set_font(&format!("{size}px {font}"));
                // Canvas2d has no direct glyph-id draw; the production backend
                // resolves glyph_id → char upstream. Stubbed as N placed runs.
                for _g in glyphs {
                    // per-glyph draw elided in the compile-check stub
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Typed-style → CSS lowering. This is the ONLY place colors become strings
// (R3/R5). Mirrors today's `render::css_color` byte-for-byte.
// ---------------------------------------------------------------------------

fn css_color(c: &Color) -> String {
    let (r, g, b, a) = c.to_rgba();
    if a >= 1.0 {
        format!("rgb({},{},{})", (r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8)
    } else {
        format!("rgba({},{},{},{})", (r * 255.0) as u8, (g * 255.0) as u8, (b * 255.0) as u8, a)
    }
}

fn cap_str(c: LineCap) -> &'static str {
    match c { LineCap::Butt => "butt", LineCap::Round => "round", LineCap::Square => "square" }
}
fn join_str(j: LineJoin) -> &'static str {
    match j { LineJoin::Miter => "miter", LineJoin::Round => "round", LineJoin::Bevel => "bevel" }
}

fn blend_css(mode: BlendMode) -> &'static str {
    match mode {
        BlendMode::Normal => "source-over",
        BlendMode::Darken => "darken",
        BlendMode::Multiply => "multiply",
        BlendMode::ColorBurn => "color-burn",
        BlendMode::Lighten => "lighten",
        BlendMode::Screen => "screen",
        BlendMode::ColorDodge => "color-dodge",
        BlendMode::Overlay => "overlay",
        BlendMode::SoftLight => "soft-light",
        BlendMode::HardLight => "hard-light",
        BlendMode::Difference => "difference",
        BlendMode::Exclusion => "exclusion",
        BlendMode::Hue => "hue",
        BlendMode::Saturation => "saturation",
        BlendMode::Color => "color",
        BlendMode::Luminosity => "luminosity",
    }
}
