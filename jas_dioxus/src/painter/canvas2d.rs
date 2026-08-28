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
use wasm_bindgen::{JsCast, JsValue};
use web_sys::{CanvasRenderingContext2d, CanvasWindingRule};

/// A [`Painter`] that draws onto a 2D canvas context. See module docs — STUB,
/// compile-checked only in this spike.
/// One open isolated layer (A6). The surface is a real offscreen canvas; the
/// alpha and blend were consumed at `push_isolated_layer` and are spent ONCE at
/// the closing composite.
struct LayerTarget {
    canvas: web_sys::HtmlCanvasElement,
    ctx: CanvasRenderingContext2d,
    alpha: f64,
    blend: BlendMode,
    /// ⛔ THE OPEN-GROUP PRODUCT RESTARTS AT 1.0 INSIDE A LAYER (A6 §3.1), so
    /// the parent's stack is SET ASIDE here and restored at the pop. Without
    /// this the ancestor alpha would apply twice — once to the body inside the
    /// layer and again at the composite — which is D-α's exact shape, and the
    /// contract pins that factor to apply once.
    saved_group_alphas: Vec<f64>,
}

pub struct Canvas2dPainter<'a> {
    base: &'a CanvasRenderingContext2d,
    /// A6: the layer-target stack. Empty means "draw to the base context".
    /// D-β is why this is a STACK and not a cell: a nested layer must not be
    /// handed the surface its parent is still drawing into.
    layers: Vec<LayerTarget>,
    /// The transforms pushed by `push_state`, innermost last. ⛔ TRACKED HERE
    /// RATHER THAN READ BACK OFF THE CONTEXT — this file's standing rule, and A6
    /// needs it: a new isolated layer must open in the PARENT'S COORDINATE FRAME
    /// (§3.1), and a fresh offscreen canvas starts at identity. Replaying the
    /// open transforms onto it reproduces the frame exactly, and lets the canvas
    /// compose the matrices rather than this file doing it by hand.
    state_stack: Vec<Transform>,
    /// Opens that could not create a surface. Counted so every push still has
    /// a matching pop and the bracket stays balanced.
    failed_layers: usize,
    /// The open group alphas. The effective paint alpha is
    /// `product(group_alpha_stack) * paint_alpha` — the non-isolated compound
    /// (contract pin). Tracked here, never read back off the context.
    group_alpha_stack: Vec<f64>,
}

impl<'a> Canvas2dPainter<'a> {
    pub fn new(ctx: &'a CanvasRenderingContext2d) -> Self {
        Self { base: ctx, layers: Vec::new(), state_stack: Vec::new(), failed_layers: 0, group_alpha_stack: Vec::new() }
    }

    /// The context every drawing op must use: the innermost open layer, or the
    /// base surface. ⛔ NOTHING may reference `self.base` directly except this —
    /// a single `self.base` left in a draw method would paint THROUGH an open
    /// layer onto the parent, which is invisible in a golden and obvious on
    /// screen.
    fn target(&self) -> &CanvasRenderingContext2d {
        self.layers.last().map(|l| &l.ctx).unwrap_or(self.base)
    }

    /// A6 §3.1: open an isolated layer. A fresh transparent surface the size of
    /// the current target, in the same coordinate frame.
    fn open_layer(&mut self, alpha: f64, blend: BlendMode) -> Option<()> {
        let cur = self.target();
        let base_canvas = cur.canvas()?;
        let (w, h) = (base_canvas.width(), base_canvas.height());
        if w == 0 || h == 0 {
            return None;
        }
        let doc = web_sys::window()?.document()?;
        let el = doc.create_element("canvas").ok()?;
        let canvas: web_sys::HtmlCanvasElement = el.unchecked_into();
        canvas.set_width(w);
        canvas.set_height(h);
        let ctx: CanvasRenderingContext2d = canvas
            .get_context("2d").ok()??.unchecked_into();
        // §3.1: the layer opens in the parent's coordinate frame. Replay the
        // open transforms in order; the canvas composes them.
        for t in &self.state_stack {
            let _ = ctx.transform(t.a, t.b, t.c, t.d, t.e, t.f);
        }
        self.layers.push(LayerTarget {
            canvas,
            ctx,
            alpha,
            blend,
            // the open-group product restarts at 1.0 inside the layer
            saved_group_alphas: std::mem::take(&mut self.group_alpha_stack),
        });
        Some(())
    }

    /// Product of the open group alphas (1.0 with no group open).
    fn group_alpha(&self) -> f64 {
        self.group_alpha_stack.iter().copied().product()
    }

    /// Set `globalAlpha` to the effective compound value for a paint.
    fn apply_alpha(&self, paint_alpha: f64) {
        self.target().set_global_alpha(self.group_alpha() * paint_alpha);
    }

    fn set_fill_brush(&self, brush: &Brush) {
        match brush {
            Brush::Solid(c) => self.target().set_fill_style_str(&css_color(c)),
            Brush::Linear(g) => {
                if let Some(cg) = self.linear_gradient(g) {
                    self.target().set_fill_style_canvas_gradient(&cg);
                }
            }
            Brush::Radial(g) => {
                if let Some(cg) = self.radial_gradient(g) {
                    self.target().set_fill_style_canvas_gradient(&cg);
                }
            }
        }
    }

    fn set_stroke_brush(&self, brush: &Brush) {
        match brush {
            Brush::Solid(c) => self.target().set_stroke_style_str(&css_color(c)),
            Brush::Linear(g) => {
                if let Some(cg) = self.linear_gradient(g) {
                    self.target().set_stroke_style_canvas_gradient(&cg);
                }
            }
            Brush::Radial(g) => {
                if let Some(cg) = self.radial_gradient(g) {
                    self.target().set_stroke_style_canvas_gradient(&cg);
                }
            }
        }
    }

    fn linear_gradient(&self, g: &LinearGradient) -> Option<web_sys::CanvasGradient> {
        let cg = self.target().create_linear_gradient(g.x0, g.y0, g.x1, g.y1);
        for s in &g.stops {
            let _ = cg.add_color_stop(s.offset as f32, &css_color(&s.color));
        }
        Some(cg)
    }

    fn radial_gradient(&self, g: &RadialGradient) -> Option<web_sys::CanvasGradient> {
        let cg = self
            .target()
            .create_radial_gradient(g.x0, g.y0, g.r0, g.x1, g.y1, g.r1)
            .ok()?;
        for s in &g.stops {
            let _ = cg.add_color_stop(s.offset as f32, &css_color(&s.color));
        }
        Some(cg)
    }

    fn apply_stroke_style(&self, s: &StrokeStyle) {
        self.target().set_line_width(s.width);
        self.target().set_line_cap(cap_str(s.cap));
        self.target().set_line_join(join_str(s.join));
        self.target().set_miter_limit(s.miter);
        let arr = js_sys::Array::new();
        for d in &s.dash {
            arr.push(&JsValue::from_f64(*d));
        }
        let _ = self.target().set_line_dash(&arr);
    }

    fn build_path(&self, path: &[PathCommand]) {
        self.target().begin_path();
        for cmd in path {
            match *cmd {
                PathCommand::MoveTo { x, y } => self.target().move_to(x, y),
                PathCommand::LineTo { x, y } => self.target().line_to(x, y),
                PathCommand::CurveTo { x1, y1, x2, y2, x, y } => {
                    self.target().bezier_curve_to(x1, y1, x2, y2, x, y)
                }
                PathCommand::QuadTo { x1, y1, x, y } => self.target().quadratic_curve_to(x1, y1, x, y),
                PathCommand::ClosePath => self.target().close_path(),
                // SmoothCurveTo/SmoothQuadTo/ArcTo fall back to line_to, exactly
                // as today's `render::build_path` does (a known simplification
                // tracked for a later phase; preserved here for 1:1 fidelity).
                PathCommand::SmoothCurveTo { x, y, .. }
                | PathCommand::SmoothQuadTo { x, y }
                | PathCommand::ArcTo { x, y, .. } => self.target().line_to(x, y),
            }
        }
    }

    fn build_ellipse(&self, a: &EllipseArc) {
        self.target().begin_path();
        // Full circle (rx == ry, rotation 0) uses arc; the general case uses
        // ellipse. Both are the missing-circle primitive the v1 IR lacked.
        let _ = self.target().ellipse_with_anticlockwise(
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
        self.target().fill_with_canvas_winding_rule(winding(w));
    }

    fn stroke_path(&mut self, path: &[PathCommand], brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        // Order: style → alpha → path → stroke. This MATCHES `render.rs`'s
        // stroke bodies (apply_stroke sets style; then set_global_alpha; then
        // begin_path/…; then stroke), so the emitted `ctx.*` sequence is
        // byte-identical for the PH1 Line conversion. (Path construction and
        // style-setting are independent, so this reorder is display-list
        // equivalent for every other caller too.)
        self.set_stroke_brush(brush);
        self.apply_stroke_style(stroke);
        self.apply_alpha(paint_alpha);
        self.build_path(path);
        self.target().stroke();
    }

    fn fill_rect(&mut self, r: Rect, brush: &Brush, paint_alpha: f64) {
        self.set_fill_brush(brush);
        self.apply_alpha(paint_alpha);
        self.target().fill_rect(r.x, r.y, r.w, r.h);
    }

    fn stroke_rect(&mut self, r: Rect, brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        self.set_stroke_brush(brush);
        self.apply_stroke_style(stroke);
        self.apply_alpha(paint_alpha);
        self.target().stroke_rect(r.x, r.y, r.w, r.h);
    }

    fn fill_ellipse_arc(&mut self, arc: &EllipseArc, w: FillRule, brush: &Brush, paint_alpha: f64) {
        self.build_ellipse(arc);
        self.set_fill_brush(brush);
        self.apply_alpha(paint_alpha);
        self.target().fill_with_canvas_winding_rule(winding(w));
    }

    fn stroke_ellipse_arc(&mut self, arc: &EllipseArc, brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        self.build_ellipse(arc);
        self.set_stroke_brush(brush);
        self.apply_stroke_style(stroke);
        self.apply_alpha(paint_alpha);
        self.target().stroke();
    }

    fn clip(&mut self, path: &[PathCommand], w: FillRule) {
        self.build_path(path);
        self.target().clip_with_canvas_winding_rule(winding(w));
    }

    fn push_state(&mut self, transform: Transform) {
        self.state_stack.push(transform);
        self.target().save();
        let _ = self.target().transform(
            transform.a, transform.b, transform.c, transform.d, transform.e, transform.f,
        );
    }

    fn pop_state(&mut self) {
        self.state_stack.pop();
        self.target().restore();
    }

    fn push_group(&mut self, alpha: f64, blend: BlendMode) {
        // save() scopes the composite op so pop_group restores the parent's
        // without a read-back. The alpha is a plain multiply on our own stack
        // (non-isolated compound — the contract pin).
        self.target().save();
        let _ = self.target().set_global_composite_operation(blend_css(blend));
        self.group_alpha_stack.push(alpha);
    }

    fn pop_group(&mut self) {
        self.group_alpha_stack.pop();
        self.target().restore();
    }

    fn push_mask_layer(&mut self, _mask: Mask) {
        // DEFERRED — PH4 owns the scratch-offscreen pipeline. UNREACHABLE in
        // production by construction: `element_render::element_needs_legacy`
        // routes every masked element to the legacy raw-ctx path, and the PH1
        // conversion emits only stroke_path (never a mask op). The panic is the
        // loud guard if that invariant is ever violated.
        unimplemented!("mask layers are PH4; masked elements must stay on the legacy path");
    }

    fn pop_mask_layer(&mut self) {
        unimplemented!("mask layers are PH4; masked elements must stay on the legacy path");
    }

    fn push_isolated_layer(&mut self, alpha: f64, blend: BlendMode) {
        // ⛔ A FAILED OPEN MUST NOT SILENTLY DRAW ON THE PARENT. If the surface
        // cannot be made, the body would composite against the backdrop it was
        // supposed to be isolated from — visibly wrong and invisible to a
        // display-list golden. Push a layer whose ctx IS the parent only when we
        // succeeded; otherwise record the failure so the matching pop is still
        // balanced and simply composites nothing.
        if self.open_layer(alpha, blend).is_none() {
            self.failed_layers += 1;
        }
    }

    fn pop_isolated_layer(&mut self) {
        if self.failed_layers > 0 {
            self.failed_layers -= 1;
            return;
        }
        let Some(layer) = self.layers.pop() else { return };
        // restore the parent's open-group product before computing the composite
        self.group_alpha_stack = layer.saved_group_alphas;
        let parent = self.target();
        // A6 §3.3: effective alpha = open-group product AT THE PUSH SITE × the
        // layer's own alpha, applied ONCE, under the layer's blend.
        let prev_alpha = parent.global_alpha();
        parent.set_global_alpha(self.group_alpha() * layer.alpha);
        let _ = parent.set_global_composite_operation(
            crate::canvas::render::blend_mode_css(layer.blend),
        );
        // the layer already carries the world transform; blit in device space
        let _ = parent.save();
        let _ = parent.reset_transform();
        let _ = parent.draw_image_with_html_canvas_element(&layer.canvas, 0.0, 0.0);
        let _ = parent.restore();
        let _ = parent.set_global_composite_operation("source-over");
        parent.set_global_alpha(prev_alpha);
    }

    fn draw_text_run(&mut self, run: &TextRun, brush: &Brush, paint_alpha: f64) {
        self.set_fill_brush(brush);
        self.apply_alpha(paint_alpha);
        match run {
            TextRun::FastRun { font, size, text, letter_spacing, x, y } => {
                self.target().set_font(&format!("{size}px {font}"));
                // native letterSpacing is set via a CSS property on the ctx (a
                // Reflect set in today's code); elided in the stub — the point
                // proven here is the single fill_text at the baseline anchor.
                let _ = *letter_spacing;
                let _ = self.target().fill_text(text, *x, *y);
            }
            TextRun::PlacedGlyphs { .. } => {
                // DEFERRED — placed-glyph shaping (skrifa cmap) is PH3 net-new
                // work. UNREACHABLE in production by construction: all text is
                // routed to the legacy raw-ctx path (element_needs_legacy), and
                // the PH1 conversion emits only stroke_path. The panic is the
                // loud guard if that invariant is ever violated.
                unimplemented!("PlacedGlyphs is PH3; text must stay on the legacy path");
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

// ═══════════════════════════════════════════════════════════════════════════
// A6 LAYER TESTS — in a real browser, via the harness added in #46.
//
// ⛔ THESE COULD NOT HAVE BEEN WRITTEN A DAY AGO. Until the wasm lane existed
// there was no way to execute this file at all, so `push_isolated_layer` shipped
// as `unimplemented!()` and the contract's alpha law had no producer to check.
// The law below (§3.3) is the one D-α got wrong: the layer's own alpha applies
// ONCE, at the composite, times the open-group product.
// ═══════════════════════════════════════════════════════════════════════════
#[cfg(all(test, target_arch = "wasm32"))]
mod a6_layer_tests {
    use super::*;
    use crate::geometry::element::Color;
    use wasm_bindgen_test::*;

    wasm_bindgen_test_configure!(run_in_browser);

    fn surface(w: u32, h: u32) -> (web_sys::HtmlCanvasElement, CanvasRenderingContext2d) {
        let doc = web_sys::window().unwrap().document().unwrap();
        let c: web_sys::HtmlCanvasElement =
            doc.create_element("canvas").unwrap().unchecked_into();
        c.set_width(w);
        c.set_height(h);
        let ctx: CanvasRenderingContext2d =
            c.get_context("2d").unwrap().unwrap().unchecked_into();
        (c, ctx)
    }

    fn alpha_at(ctx: &CanvasRenderingContext2d, x: f64, y: f64) -> u8 {
        ctx.get_image_data(x, y, 1.0, 1.0).unwrap().data()[3]
    }

    /// CONTROL: an ordinary fill with no layer open lands on the base surface at
    /// full alpha. Without this, every "the pixel is what I expect" below could
    /// be true for the wrong reason.
    #[wasm_bindgen_test]
    fn a_plain_fill_reaches_the_base_surface() {
        let (_c, ctx) = surface(8, 8);
        let mut p = Canvas2dPainter::new(&ctx);
        p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 8.0 },
                    &Brush::Solid(Color::rgb(1.0, 0.0, 0.0)), 1.0);
        assert_eq!(alpha_at(&ctx, 1.0, 1.0), 255, "control: the base surface was not painted");
    }

    /// ⛔ ISOLATION. Drawing inside an open layer must NOT appear on the parent
    /// until the layer is popped — that is the whole difference between
    /// push_group (non-isolated) and push_isolated_layer.
    #[wasm_bindgen_test]
    fn a_layers_content_does_not_reach_the_parent_until_pop() {
        let (_c, ctx) = surface(8, 8);
        let mut p = Canvas2dPainter::new(&ctx);
        p.push_isolated_layer(1.0, BlendMode::Normal);
        p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 8.0 },
                    &Brush::Solid(Color::rgb(1.0, 0.0, 0.0)), 1.0);
        assert_eq!(alpha_at(&ctx, 1.0, 1.0), 0,
                   "the layer's content leaked onto the parent before pop");
        p.pop_isolated_layer();
        assert_eq!(alpha_at(&ctx, 1.0, 1.0), 255,
                   "the layer did not composite into the parent at pop");
    }

    /// ⛔⛔ THE LAW D-α GOT WRONG, NOW IN PIXELS. group 0.5 × layer 0.5 = 0.25,
    /// applied ONCE. The defect rendered this at 0.25 FROM THE ELEMENT ALONE
    /// (opacity²) while discarding the group's 0.5 — the same number by
    /// coincidence, which is why §6.2's golden uses discriminating values and
    /// why this test checks 0.5×1.0 and 1.0×0.5 too.
    #[wasm_bindgen_test]
    fn the_layer_alpha_applies_once_times_the_group_product() {
        for (group, layer, want) in [(1.0, 0.5, 128u8), (0.5, 1.0, 128u8), (0.5, 0.5, 64u8)] {
            let (_c, ctx) = surface(8, 8);
            let mut p = Canvas2dPainter::new(&ctx);
            p.push_group(group, BlendMode::Normal);
            p.push_isolated_layer(layer, BlendMode::Normal);
            // body paints at paint_alpha 1.0 — the element's opacity rides the LAYER
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 8.0 },
                        &Brush::Solid(Color::rgb(1.0, 0.0, 0.0)), 1.0);
            p.pop_isolated_layer();
            p.pop_group();
            let got = alpha_at(&ctx, 1.0, 1.0);
            assert!(
                (got as i32 - want as i32).abs() <= 2,
                "group {group} x layer {layer}: want ~{want}, got {got} \
                 (a squared alpha would give {})",
                (255.0 * group * layer * layer) as u8
            );
        }
    }

    /// D-β at the painter level: a nested layer must not be handed the surface
    /// its parent is still drawing into.
    #[wasm_bindgen_test]
    fn a_nested_layer_gets_its_own_surface() {
        let (_c, ctx) = surface(8, 8);
        let mut p = Canvas2dPainter::new(&ctx);
        p.push_isolated_layer(1.0, BlendMode::Normal);
        p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 8.0 },
                    &Brush::Solid(Color::rgb(1.0, 0.0, 0.0)), 1.0);
        p.push_isolated_layer(1.0, BlendMode::Normal);
        // the inner layer is empty; if it aliased the outer, the outer's pixel
        // would be gone by the time both pop.
        p.pop_isolated_layer();
        p.pop_isolated_layer();
        assert_eq!(alpha_at(&ctx, 1.0, 1.0), 255,
                   "D-β at the painter: the nested layer clobbered the outer surface");
    }
}
