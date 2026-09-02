//! [`Canvas2dPainter`] — the production Canvas2D backend for the [`Painter`]
//! seam. It maps 1:1 onto `web_sys::CanvasRenderingContext2d` call sequences.
//!
//! STATUS: WIRED, and EXECUTED. `canvas/render.rs` routes convertible leaf
//! paints through this painter (PH1/PH2) and, since PH4, a fully convertible
//! masked element through the A6 element bracket. The bodies are exercised in a
//! real browser by the `wasm-canvas` lane, not merely compile-checked.
//!
//! ⛔ THE PARAGRAPH THIS REPLACES SAID "SPIKE STATUS: COMPILE-CHECKED, not run
//! … NOT wired into `canvas/render.rs` — the FLIP is unratified, so production
//! conversion is forbidden." Every clause of that is now false: the wasm lane
//! runs these bodies (#46, #55), the leaf routes wired in PH1, the council
//! ratified the Painter-seam flip on 2026-08-29 and the Captain ruled the
//! production conversion GO on 2026-08-30. It is struck rather than softened,
//! because a stale prohibition in a module header is read as a live fence.
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
use crate::surface::web::{blend_mode_css, CompositeOp, WebSurface};
use crate::surface::PixelSurface;
use wasm_bindgen::JsValue;
use web_sys::{CanvasRenderingContext2d, CanvasWindingRule};

/// A [`Painter`] that draws onto a 2D canvas context. See module docs — STUB,
/// compile-checked only in this spike.
/// One open isolated layer (A6). The surface is a real offscreen canvas; the
/// alpha and blend were consumed at `push_isolated_layer` and are spent ONCE at
/// the closing composite.
enum LayerKind {
    /// A6 §3.1 — an isolated layer. `alpha`/`blend` are spent ONCE at the
    /// closing composite.
    Isolated { alpha: f64, blend: BlendMode },
    /// A6 §3.2 — the MASK ARTWORK surface of the enclosing isolated layer. It
    /// composites by UPDATING THE PARENT'S ALPHA CHANNEL under `law`, never by
    /// drawing the artwork's colour into the parent.
    Mask { law: Mask },
}

struct LayerTarget {
    /// The layer's offscreen surface — a caller-owned `WebSurface`, so the
    /// luminance law reaches it through the surface service and not through
    /// a raw pixel call of this backend's own.
    surface: WebSurface,
    kind: LayerKind,
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
    /// ⛔ THE FRAME THE BASE CONTEXT WAS ALREADY IN WHEN THIS PAINTER WAS
    /// HANDED IT — `None` for a painter that owns its context from identity.
    ///
    /// PH4 (the production conversion) is why this exists, and the failure it
    /// prevents is total rather than subtle. `open_layer` builds a FRESH
    /// offscreen canvas, which starts at IDENTITY, and reproduces the frame by
    /// replaying [`Self::state_stack`]. That is exact for a painter that has
    /// seen every transform — the corpus driver and the browser tests, which
    /// start at identity. It is WRONG for production: `canvas/render.rs`
    /// establishes the view transform (pan/zoom) and every ancestor element's
    /// transform with raw `ctx.transform` calls this painter never saw, so the
    /// replay reproduces only the suffix and an isolated layer opens at the
    /// wrong origin and scale. The body would then be blitted back in device
    /// space — drawn in the wrong place, at full fidelity, with nothing
    /// reporting it.
    ///
    /// It is a CONSTRUCTOR PARAMETER, not a read-back, so this file's standing
    /// rule survives: the one place that reads a transform off a context is
    /// `canvas::render`, which already does exactly that for the legacy masked
    /// path (`read_ctx_transform`). The value crosses the seam explicitly.
    base_frame: Option<Transform>,
}

impl<'a> Canvas2dPainter<'a> {
    pub fn new(ctx: &'a CanvasRenderingContext2d) -> Self {
        Self { base: ctx, layers: Vec::new(), state_stack: Vec::new(), failed_layers: 0, group_alpha_stack: Vec::new(), base_frame: None }
    }

    /// As [`Self::new`], but told the world transform `ctx` is ALREADY in.
    ///
    /// Use this whenever the context was positioned by a caller outside this
    /// painter and the painter may open a layer — that is, from production.
    /// See [`Self::base_frame`] for what goes wrong without it.
    pub fn at_frame(ctx: &'a CanvasRenderingContext2d, frame: Transform) -> Self {
        Self { base_frame: Some(frame), ..Self::new(ctx) }
    }

    /// The context every drawing op must use: the innermost open layer, or the
    /// base surface. ⛔ NOTHING may reference `self.base` directly except this —
    /// a single `self.base` left in a draw method would paint THROUGH an open
    /// layer onto the parent, which is invisible in a golden and obvious on
    /// screen.
    fn target(&self) -> &CanvasRenderingContext2d {
        self.layers.last().map(|l| l.surface.ctx()).unwrap_or(self.base)
    }

    /// A6 §3.1: open an isolated layer. A fresh transparent surface the size of
    /// the current target, in the same coordinate frame.
    fn open_layer(&mut self, kind: LayerKind) -> Option<()> {
        let cur = self.target();
        let base_canvas = cur.canvas()?;
        let (w, h) = (base_canvas.width(), base_canvas.height());
        if w == 0 || h == 0 {
            return None;
        }
        let surface = WebSurface::offscreen(w, h)?;
        let ctx = surface.ctx();
        // §3.1: the layer opens in the parent's coordinate frame. Replay the
        // open transforms in order; the canvas composes them.
        // ⛔ SEEDED WITH THE FRAME THE BASE CONTEXT ARRIVED IN, when there is
        // one. The replay below can only reproduce what THIS painter pushed; a
        // production caller has already applied the view transform and every
        // ancestor element transform with raw `ctx.*` calls. See `base_frame`.
        if let Some(t) = self.base_frame {
            let _ = ctx.transform(t.a, t.b, t.c, t.d, t.e, t.f);
        }
        for t in &self.state_stack {
            let _ = ctx.transform(t.a, t.b, t.c, t.d, t.e, t.f);
        }
        self.layers.push(LayerTarget {
            surface,
            kind,
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
    /// ⚖️ THIS BACKEND ANSWERS YES — AND THE FIXTURES SAY SO, NOT THIS COMMENT.
    ///
    /// * `IsolatedLayers` — the layer-target stack landed in #47;
    /// * `MaskLayers` — push/pop_mask_layer EXECUTE since #55;
    /// * `NonNormalBlend` — and this answer is now LOAD-BEARING, so it is stated
    ///   with where to check it: `push_group` sets the CSS composite operation
    ///   (`surface::web::blend_mode_css`, the one copy), AND `pop_isolated_layer`
    ///   reads the layer's own blend back out of `LayerKind::Isolated` and
    ///   composites under it before restoring `source-over`. Both carriers are
    ///   honoured — the blend reaches a point of USE here, not merely a point of
    ///   storage, and `a_groups_blend_mode_reaches_the_primitives_inside_it`
    ///   is where the first carrier is checked in pixels.
    ///
    /// The corpus driver below
    /// ([`tests::every_recorded_scene_replays_through_canvas2d`]) drives all 20
    /// recorded scenes through this impl IN A REAL BROWSER and asserts that
    /// nothing is refused; the arm right after it asserts that this answer
    /// AGREES with what that driver measured. A wrong answer here reds there.
    fn supports(&self, _cap: crate::painter::capability::Capability) -> bool {
        true
    }

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
        let _ = self.target().set_global_composite_operation(blend_mode_css(blend));
        self.group_alpha_stack.push(alpha);
    }

    fn pop_group(&mut self) {
        self.group_alpha_stack.pop();
        self.target().restore();
    }

    fn push_mask_layer(&mut self, mask: Mask) {
        // ⛔ LEGAL ONLY INSIDE AN ISOLATED LAYER (A6 §3.2). Outside one there is
        // no surface whose alpha this could update, and the op was semantically
        // vacant before the amendment. The contract permits an impl to panic;
        // this one does, loudly, rather than painting something plausible.
        //
        // A FAILED enclosing open counts as "no layer": `failed_layers` means
        // the body is drawing straight onto the parent, and clipping the parent
        // by this mask would erase artwork the layer was supposed to isolate.
        // The mask is dropped and BALANCED instead -- the same choice
        // push_isolated_layer already makes for its own failed opens.
        if self.failed_layers > 0 || !matches!(
            self.layers.last().map(|l| &l.kind), Some(LayerKind::Isolated { .. })
        ) {
            if self.layers.is_empty() && self.failed_layers == 0 {
                panic!("push_mask_layer outside an isolated layer -- A6 §3.2 \
                        forbids it; the mask has no surface to clip");
            }
            self.failed_layers += 1;
            return;
        }
        if self.open_layer(LayerKind::Mask { law: mask }).is_none() {
            self.failed_layers += 1;
        }
    }

    fn pop_mask_layer(&mut self) {
        if self.failed_layers > 0 {
            self.failed_layers -= 1;
            return;
        }
        let Some(layer) = self.layers.pop() else { return };
        let LayerKind::Mask { law } = layer.kind else {
            panic!("pop_mask_layer with an ISOLATED layer open -- brackets must nest (A6 §3.2)");
        };
        self.group_alpha_stack = layer.saved_group_alphas;

        // ⛔ THE MASK UPDATES THE PARENT'S ALPHA IN PLACE -- it never draws its
        // own colour into the parent. Every law below is a composite operation
        // chosen so the artwork contributes ONLY through the destination's
        // alpha channel:
        //
        //   LuminanceClipIn        α_S ← α_S · M, M = A·(0.299R+0.587G+0.114B)/255
        //   AlphaClipOut           α_S ← α_S · (1 − M), raw A
        //   AlphaRevealOutsideBbox α_S ← α_S · M inside bbox, unchanged outside
        //
        // BT.601 is normative for the luminance law (§A6), and the promotion is
        // the surface service's -- the SAME function the legacy path uses, not
        // a second implementation that could drift from it. (It used to be
        // reached INSIDE `canvas::render`, a backend depending on the web-only
        // walk it is meant to replace; `surface` is host-independent.)
        let (w, h) = layer.surface.size();
        if w == 0 || h == 0 {
            return;
        }
        if matches!(law, Mask::LuminanceClipIn) {
            // Promote on the MASK surface, in device space, before the blit.
            // get_image_data ignores the ctx transform, which is what we want:
            // this is a per-pixel channel rewrite, not a drawing operation.
            if crate::surface::promote_to_luminance(&layer.surface, 0, 0, w, h).is_none() {
                // ⚠️ FAIL SOFT, LIKE LEGACY. If ImageData is unavailable the
                // legacy path falls back to the raw-alpha composite rather than
                // dropping the mask; an unmasked element is a worse lie than a
                // slightly wrong mask. The fallthrough below does exactly that.
            }
        }

        let parent = self.target();
        // ⛔ THE OUTER save/restore IS FOR THE CLIP, AND FOR NOTHING ELSE NOW.
        // The bbox arm sets a clip under the CURRENT transform, and only a
        // save/restore can take it off again. The composite's transform, alpha
        // and operation are scoped by `composite_onto`'s own save/restore, which
        // is what retired the manual `prev_alpha` dance that used to live here.
        //
        // ⚠️ MEASURED 2026-09-02: DELETING THIS `save()` KILLS NO TEST, AND IT
        // STAYS ANYWAY. `parent` here is the enclosing ISOLATED LAYER's surface;
        // a clip leaked onto it lands on a canvas `pop_isolated_layer` then
        // composites WHOLE (a device-space drawImage, which no clip on the
        // source affects) and discards, and A6 §3.2 forbids painting in the
        // window between the two pops. So this is defensive depth whose
        // unobservability rests on a rule kept somewhere else — which is exactly
        // the kind of code that must not ALSO be written as if it knew the rule.
        // See `a_reveal_bbox_mask_does_not_leak_its_clip_onto_the_next_element`
        // for the surviving mutant, recorded with its reason.
        let _ = parent.save();
        let op = match law {
            Mask::LuminanceClipIn => CompositeOp::DestinationIn,
            Mask::AlphaClipOut => CompositeOp::DestinationOut,
            Mask::AlphaRevealOutsideBbox { bbox } => {
                // The bbox arrives precomputed (§3.3) as the bounds OF the
                // transformed mask subtree, already in THIS frame — the frame
                // the layer was pushed in, where the clip is applied (the
                // ruled contract, 2026-08-31).
                // Clip UNDER the current transform so the rect lands where the
                // document says; the service resets to device space for the
                // blit, and a clip is rasterised into device space when it is
                // SET, so it still holds after that reset. Outside the clip the
                // parent's alpha is untouched, which is the whole point of this
                // law.
                let _ = parent.begin_path();
                parent.rect(bbox.x, bbox.y, bbox.w, bbox.h);
                parent.clip();
                CompositeOp::DestinationIn
            }
        };
        // ⚖️ ALPHA 1.0, AND IT IS NOT A DEFAULT: a mask application is a CHANNEL
        // UPDATE, not an alpha-weighted blit, so it runs at 1.0 whatever the
        // open groups carry.
        layer.surface.composite_onto(parent, op, 1.0);
        let _ = parent.restore();
        // The parent's operation is forced back rather than merely restored,
        // exactly as before this refactor: `restore()` above already returns it,
        // and this line is kept because changing it would be a behaviour change
        // dressed as a cleanup.
        let _ = parent.set_global_composite_operation("source-over");
    }

    fn push_isolated_layer(&mut self, alpha: f64, blend: BlendMode) {
        // ⛔ A FAILED OPEN MUST NOT SILENTLY DRAW ON THE PARENT. If the surface
        // cannot be made, the body would composite against the backdrop it was
        // supposed to be isolated from — visibly wrong and invisible to a
        // display-list golden. Push a layer whose ctx IS the parent only when we
        // succeeded; otherwise record the failure so the matching pop is still
        // balanced and simply composites nothing.
        if self.open_layer(LayerKind::Isolated { alpha, blend }).is_none() {
            self.failed_layers += 1;
        }
    }

    fn pop_isolated_layer(&mut self) {
        if self.failed_layers > 0 {
            self.failed_layers -= 1;
            return;
        }
        let Some(layer) = self.layers.pop() else { return };
        // ⛔ THE BRACKETS STRICTLY NEST (§3.2). Closing an isolated layer while a
        // mask bracket is still open would composite the ARTWORK as if it were
        // the layer — silently, and invisibly to a display-list golden.
        let LayerKind::Isolated { alpha: layer_alpha, blend: layer_blend } = layer.kind else {
            panic!("pop_isolated_layer with a MASK layer open -- brackets must nest (A6 §3.2)");
        };
        // restore the parent's open-group product before computing the composite
        self.group_alpha_stack = layer.saved_group_alphas;
        let parent = self.target();
        // A6 §3.3: effective alpha = open-group product AT THE PUSH SITE × the
        // layer's own alpha, applied ONCE, under the layer's blend. The layer
        // already carries the world transform, so the blit is in device space --
        // which is what the service does, and why it is the service.
        //
        // ⚖️ `CompositeOp::Blend(mode).css()` IS `blend_mode_css(mode)`, the same
        // function this site used to call directly; the enum is not a second
        // vocabulary, it is the one place the three composite kinds are named.
        layer.surface.composite_onto(
            parent,
            CompositeOp::Blend(layer_blend),
            self.group_alpha() * layer_alpha,
        );
        // Forced back rather than merely restored, exactly as before this
        // refactor -- see the note in `pop_mask_layer`.
        let _ = parent.set_global_composite_operation("source-over");
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

// ⛔ THE BLEND TABLE IS NOT HERE, AND IT USED TO BE. This file carried its own
// 16-arm `blend_css` — a second, ungated copy of `surface::web::blend_mode_css`,
// which `canvas::render` already used and which a native test pins across ALL
// SIXTEEN variants (`blend_mode_css_maps_all_sixteen_variants`). The 2026-09-02
// census found the duplicate the way it finds everything: a mutant mis-mapping
// one of its rows survived the entire browser lane, because the only caller of
// the copy is `push_group` and no pixel test read it. Routing the call site at
// the one copy puts this backend's blend lowering under a gate that already
// exists, instead of asking for a seventeenth fixture.


// ═══════════════════════════════════════════════════════════════════════════
// A6 LAYER TESTS — in a real browser, via the harness added in #46.
//
// ⛔ THESE COULD NOT HAVE BEEN WRITTEN A DAY AGO. Until the wasm lane existed
// there was no way to execute this file at all, so `push_isolated_layer` shipped
// as `unimplemented!()` and the contract's alpha law had no producer to check.
// The law below (§3.3) is the one D-α got wrong: the layer's own alpha applies
// ONCE, at the composite, times the open-group product.
// ═══════════════════════════════════════════════════════════════════════════
/// THE BROWSER PROBE — one copy of the three helpers every pixel arm in this
/// file needs. They were private to `a6_layer_tests` until the census below
/// grew a second module that needs exactly the same three; a second copy of a
/// probe is how two lanes start measuring two different things.
#[cfg(all(test, target_arch = "wasm32"))]
mod browser_probe {
    use super::CanvasRenderingContext2d;
    use wasm_bindgen::JsCast;

    pub(super) fn surface(w: u32, h: u32) -> (web_sys::HtmlCanvasElement, CanvasRenderingContext2d) {
        let doc = web_sys::window().unwrap().document().unwrap();
        let c: web_sys::HtmlCanvasElement =
            doc.create_element("canvas").unwrap().unchecked_into();
        c.set_width(w);
        c.set_height(h);
        let ctx: CanvasRenderingContext2d =
            c.get_context("2d").unwrap().unwrap().unchecked_into();
        (c, ctx)
    }

    pub(super) fn alpha_at(ctx: &CanvasRenderingContext2d, x: f64, y: f64) -> u8 {
        ctx.get_image_data(x, y, 1.0, 1.0).unwrap().data()[3]
    }

    pub(super) fn rgba_at(ctx: &CanvasRenderingContext2d, x: f64, y: f64) -> (u8, u8, u8, u8) {
        let d = ctx.get_image_data(x, y, 1.0, 1.0).unwrap().data();
        (d[0], d[1], d[2], d[3])
    }
}

#[cfg(all(test, target_arch = "wasm32"))]
mod a6_layer_tests {
    use super::browser_probe::{alpha_at, rgba_at, surface};
    use super::*;
    use crate::geometry::element::Color;
    use crate::painter::capability::{Capability, Caps};
    use wasm_bindgen_test::*;

    wasm_bindgen_test_configure!(run_in_browser);

    /// A masked body: red over the whole surface, then a mask bracket whose
    /// artwork is `paint` — run through the REAL bracket, so every assertion
    /// below is about the shipped code path and not a fixture of the test's.
    fn masked(law: Mask, paint: impl Fn(&mut Canvas2dPainter))
        -> (web_sys::HtmlCanvasElement, CanvasRenderingContext2d) {
        let (c, ctx) = surface(8, 8);
        {
            let mut p = Canvas2dPainter::new(&ctx);
            p.push_isolated_layer(1.0, BlendMode::Normal);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 8.0 },
                        &Brush::Solid(Color::rgb(1.0, 0.0, 0.0)), 1.0);
            p.push_mask_layer(law);
            paint(&mut p);
            p.pop_mask_layer();
            p.pop_isolated_layer();
        }
        (c, ctx)
    }

    fn white(p: &mut Canvas2dPainter, x: f64, w: f64) {
        p.fill_rect(Rect { x, y: 0.0, w, h: 8.0 }, &Brush::Solid(Color::WHITE), 1.0);
    }
    fn black(p: &mut Canvas2dPainter, x: f64, w: f64) {
        p.fill_rect(Rect { x, y: 0.0, w, h: 8.0 }, &Brush::Solid(Color::BLACK), 1.0);
    }

    /// ⛔⛔ THE LAYER MUST OPEN IN THE FRAME THE BASE CONTEXT ARRIVED IN.
    ///
    /// PH4's blocker, in pixels. `open_layer` builds a FRESH canvas — identity
    /// transform — and reproduces the frame by replaying the transforms THIS
    /// painter was told about. A production caller has already applied the view
    /// transform and every ancestor element transform with raw `ctx.*` calls
    /// the painter never saw, so the replay reproduces only the suffix: the
    /// layer draws at the wrong origin and is then blitted back in DEVICE space,
    /// putting the element somewhere else on the canvas at full fidelity.
    ///
    /// ⚖️ ONE VARIABLE. Both arms use the same pre-translated context, the same
    /// single fill at the same coordinates, the same push/pop. Only the
    /// CONSTRUCTOR differs. Differing outputs would prove an arm can fire; the
    /// single variable is what makes the difference attributable to the frame.
    #[wasm_bindgen_test]
    fn an_isolated_layer_opens_in_the_frame_the_base_context_arrived_in() {
        let frame = Transform { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 4.0, f: 0.0 };
        // The frame is on the CONTEXT before either painter is built — exactly
        // production's situation.
        let arm = |told: bool| -> (u8, u8) {
            let (_c, ctx) = surface(8, 8);
            let _ = ctx.translate(4.0, 0.0);
            {
                let mut p = if told {
                    Canvas2dPainter::at_frame(&ctx, frame)
                } else {
                    Canvas2dPainter::new(&ctx)
                };
                p.push_isolated_layer(1.0, BlendMode::Normal);
                p.fill_rect(Rect { x: 0.0, y: 0.0, w: 2.0, h: 8.0 },
                            &Brush::Solid(Color::WHITE), 1.0);
                p.pop_isolated_layer();
            }
            // (1,1) is where an IDENTITY-framed layer lands; (5,1) is where the
            // translated frame puts it.
            (alpha_at(&ctx, 1.0, 1.0), alpha_at(&ctx, 5.0, 1.0))
        };

        // CONTROL FIRST: an unframed painter really does land in the wrong
        // place, so the arm below is not passing for want of a live surface.
        assert_eq!(arm(false), (255, 0),
                   "an unframed layer should land at the identity origin -- if it \
                    does not, this test is measuring something else");
        assert_eq!(arm(true), (0, 255),
                   "a framed layer must land where the base context is pointing");
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

    // ═══════════════════════════════════════════════════════════════════
    // PH4 — THE MASK HALF OF THE BACKEND. Until this landed,
    // `push_mask_layer` was `unimplemented!()` and A6's bracket could not
    // execute: #47 gave the layer stack, and the plan of record mistook that
    // for "the backend". These are the first mask pixels this repo has ever
    // produced through the seam.
    // ═══════════════════════════════════════════════════════════════════

    /// CONTROL, FIRST. A fully-opaque WHITE mask keeps everything — M = 1
    /// everywhere. If this fails, every cut below could be "the pipeline erases
    /// unconditionally" rather than the law doing its job.
    #[wasm_bindgen_test]
    fn a_full_white_luminance_mask_keeps_the_element() {
        let (_c, ctx) = masked(Mask::LuminanceClipIn, |p| white(p, 0.0, 8.0));
        assert_eq!(alpha_at(&ctx, 4.0, 4.0), 255,
                   "control: an opaque white luminance mask must keep the element");
    }

    // ═══════════════════════════════════════════════════════════════════
    // ROW CW — TWO ARMS A MUTATION PASS DEMANDED, AND THEY ARE OLDER THAN THE
    // ROW THAT FOUND THEM.
    //
    // Routing the three hand-rolled blits through `WebSurface::composite_onto`
    // was behaviour-preserving, so its evidence had to be a MUTATION pass
    // rather than a red. Two mutants survived the whole browser lane:
    //
    //   - the isolated layer composited `Normal` instead of its own blend
    //   - the outer `save()` in `pop_mask_layer` was deleted (the reveal-bbox
    //     clip then escapes the bracket, and `restore()` pops the caller's state)
    //
    // ⚖️ AND BOTH SURVIVED AGAINST THE PRE-REFACTOR CODE TOO — driven there as
    // the control, because "a mutant survived my change" and "a mutant survives
    // this code" are different claims and only the second one is true. These are
    // PRE-EXISTING holes the refactor's evidence requirement EXPOSED, which is
    // the argument for driving mutants at a refactor at all.
    //
    // 📌 The first is the same family flask reported one PR earlier on the
    // Direct2D side: a Multiply-only suite could not tell a commutative blend
    // from a swapped one. Neither backend's layer blend had a pixel that could
    // fail. Both do now.
    // ═══════════════════════════════════════════════════════════════════

    /// ⛔ THE ISOLATED LAYER'S BLEND MUST REACH THE COMPOSITE. `push_isolated_layer`
    /// carries `(alpha, blend)` and A6 §3.3 spends both ONCE, at the closing
    /// composite. A backend that opened the layer and closed it `source-over`
    /// would draw a plausible picture with the blend silently discarded — and
    /// until this arm, would have passed every test in this file.
    ///
    /// ⚖️ MULTIPLY IS DISCRIMINATING HERE ONLY BECAUSE OF THE COLOURS. Backdrop
    /// RED (255,0,0) under a mid-grey (128,128,128) source: `multiply` gives
    /// (128,0,0), `source-over` gives (128,128,128). The green channel is the
    /// whole assertion, and it is 128 apart — a fixture whose backdrop was grey
    /// would agree under both and prove nothing.
    #[wasm_bindgen_test]
    fn an_isolated_layers_blend_reaches_its_closing_composite() {
        let (_c, ctx) = surface(8, 8);
        let mut p = Canvas2dPainter::new(&ctx);
        // The backdrop, painted straight onto the target.
        p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 8.0 },
                    &Brush::Solid(Color::rgb(1.0, 0.0, 0.0)), 1.0);
        // A layer carrying MULTIPLY, whose body is a mid grey.
        p.push_isolated_layer(1.0, BlendMode::Multiply);
        p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 8.0 },
                    &Brush::Solid(Color::rgb(128.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0)), 1.0);
        p.pop_isolated_layer();

        let (r, g, b, a) = rgba_at(&ctx, 4.0, 4.0);
        assert_eq!(a, 255, "the composite must land at all");
        assert!(g <= 4 && b <= 4,
                "the layer closed SOURCE-OVER: multiply against a red backdrop \
                 zeroes green and blue, and this pixel is ({r},{g},{b},{a})");
        assert!((120..=136).contains(&r),
                "multiply of 255 x 128 is 128; got r={r} in ({r},{g},{b},{a})");
    }

    /// ⛔ THE REVEAL-BBOX BRACKET MUST NOT EAT THE NEXT ELEMENT. A leaked clip is
    /// the nastiest shape in this file: everything the bracket itself does looks
    /// right, and the NEXT element silently loses whatever falls outside a
    /// rectangle it has no relationship to. So the assertion is about a draw
    /// that happens AFTER the bracket closes, far outside the mask's bbox —
    /// nothing inside the bracket can state it.
    ///
    /// ⛔⛔ AND THIS ARM DOES NOT KILL THE MUTANT IT WAS WRITTEN FOR. I AM SAYING
    /// SO RATHER THAN LETTING A GREEN STAND IN FOR ONE. Deleting the outer
    /// `save()` in `pop_mask_layer` leaves this test PASSING, and the reason is
    /// worth more than the arm: `pop_mask_layer`'s `parent` is the enclosing
    /// ISOLATED LAYER's surface, not the real target. A clip leaked there lands
    /// on a canvas that `pop_isolated_layer` composites WHOLE — a device-space
    /// `drawImage`, which no clip on the source affects — and then discards. A6
    /// §3.2 forbids painting between `pop_mask_layer` and `pop_isolated_layer`,
    /// so nothing ever draws into the window where the leak is visible.
    ///
    /// ⇒ **the `save()` is DEFENSIVE DEPTH, and §3.2 — not a pixel — is what
    /// makes it unobservable.** It stays: code that is correct only because a
    /// rule elsewhere holds should not also be written as if it knew that. The
    /// mutant is recorded as surviving WITH ITS REASON, which is the honest
    /// alternative to inventing a fixture for a shape (a bare mask layer with no
    /// isolated layer around it) that `emit_masked_element` never emits.
    #[wasm_bindgen_test]
    fn a_reveal_bbox_mask_does_not_leak_its_clip_onto_the_next_element() {
        let (_c, ctx) = surface(8, 8);
        {
            let mut p = Canvas2dPainter::new(&ctx);
            // A masked element confined to the TOP-LEFT 2x2 by its bbox.
            p.push_isolated_layer(1.0, BlendMode::Normal);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 2.0, h: 2.0 },
                        &Brush::Solid(Color::rgb(1.0, 0.0, 0.0)), 1.0);
            p.push_mask_layer(Mask::AlphaRevealOutsideBbox {
                bbox: Rect { x: 0.0, y: 0.0, w: 2.0, h: 2.0 },
            });
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 2.0, h: 2.0 },
                        &Brush::Solid(Color::rgb(1.0, 1.0, 1.0)), 1.0);
            p.pop_mask_layer();
            p.pop_isolated_layer();

            // ...and now a SECOND element, far outside that bbox.
            p.fill_rect(Rect { x: 5.0, y: 5.0, w: 3.0, h: 3.0 },
                        &Brush::Solid(Color::rgb(0.0, 0.0, 1.0)), 1.0);
        }
        assert_eq!(alpha_at(&ctx, 6.0, 6.0), 255,
                   "the mask's bbox clip escaped its bracket and ate the NEXT \
                    element, which is drawn nowhere near it");
    }

    /// ⛔ THE jas ASYMMETRY, AND IT IS THE WHOLE REASON THE ENUM HAS THREE
    /// VARIANTS: `LuminanceClipIn` reads LUMINANCE, the others read RAW ALPHA.
    /// A BLACK, FULLY OPAQUE mask is the discriminating fixture — raw alpha says
    /// "keep everything" (A = 255), luminance says "keep nothing" (Y = 0). A
    /// backend that quietly used alpha here would pass every white-mask test.
    #[wasm_bindgen_test]
    fn luminance_reads_luminance_not_alpha() {
        let (_c, ctx) = masked(Mask::LuminanceClipIn, |p| black(p, 0.0, 8.0));
        assert_eq!(alpha_at(&ctx, 4.0, 4.0), 0,
                   "an opaque BLACK luminance mask must cut the element to nothing; \
                    255 here means the backend read alpha instead of luminance");
    }

    /// The mask's own COLOUR must never reach the parent — the bracket updates
    /// the destination's ALPHA and nothing else. A white artwork over a red body
    /// must leave the surviving pixel RED.
    #[wasm_bindgen_test]
    fn the_mask_updates_alpha_and_never_tints_the_body() {
        let (_c, ctx) = masked(Mask::LuminanceClipIn, |p| white(p, 0.0, 8.0));
        let (r, g, b, a) = rgba_at(&ctx, 4.0, 4.0);
        assert_eq!((r, g, b, a), (255, 0, 0, 255),
                   "the body must stay red; a white pixel means the artwork was \
                    drawn INTO the parent instead of clipping it");
    }

    /// Partial coverage: where the artwork is absent the element is cut.
    #[wasm_bindgen_test]
    fn luminance_clip_in_cuts_where_the_artwork_is_absent() {
        let (_c, ctx) = masked(Mask::LuminanceClipIn, |p| white(p, 0.0, 4.0));
        assert_eq!(alpha_at(&ctx, 1.0, 4.0), 255, "kept under the artwork");
        assert_eq!(alpha_at(&ctx, 6.0, 4.0), 0, "cut where there is no artwork");
    }

    /// ⛔ AND THE TWO LAWS MUST DISAGREE ON THE SAME FIXTURE, or one of them is
    /// decoration. Same black artwork over the left half:
    ///   ClipIn  — luminance 0 under it, nothing beside it  → BOTH halves cut
    ///   ClipOut — raw alpha erases under it, leaves beside → LEFT cut, RIGHT kept
    /// The right half is the discriminator.
    #[wasm_bindgen_test]
    fn clip_out_and_clip_in_differ_on_the_same_artwork() {
        let (_c, ci) = masked(Mask::LuminanceClipIn, |p| black(p, 0.0, 4.0));
        let (_c2, co) = masked(Mask::AlphaClipOut, |p| black(p, 0.0, 4.0));
        assert_eq!(alpha_at(&ci, 1.0, 4.0), 0, "ClipIn: black luminance cuts under the artwork");
        assert_eq!(alpha_at(&co, 1.0, 4.0), 0, "ClipOut: opaque alpha erases under the artwork");
        assert_eq!(alpha_at(&ci, 6.0, 4.0), 0, "ClipIn: no artwork beside it, so cut");
        assert_eq!(alpha_at(&co, 6.0, 4.0), 255, "ClipOut: untouched beside the artwork");
    }

    /// The reveal law has THREE regions, and only a fixture with all three can
    /// tell it from `LuminanceClipIn`: inside the bbox it clips; OUTSIDE the
    /// bbox the element is untouched even where no artwork exists.
    #[wasm_bindgen_test]
    fn reveal_outside_bbox_leaves_the_outside_untouched() {
        let bbox = Rect { x: 0.0, y: 0.0, w: 4.0, h: 8.0 };
        let (_c, ctx) = masked(Mask::AlphaRevealOutsideBbox { bbox },
                               |p| white(p, 0.0, 2.0));
        assert_eq!(alpha_at(&ctx, 1.0, 4.0), 255, "inside bbox, under artwork: kept");
        assert_eq!(alpha_at(&ctx, 3.0, 4.0), 0, "inside bbox, no artwork: cut");
        assert_eq!(alpha_at(&ctx, 6.0, 4.0), 255,
                   "OUTSIDE the bbox: untouched — this is the region that \
                    distinguishes the reveal law from a plain clip-in");
    }

    /// The mask composite must not disturb the layer's own alpha law: the D-α
    /// product still applies ONCE at the layer's pop, with a mask in between.
    #[wasm_bindgen_test]
    fn the_layer_alpha_law_survives_a_mask_bracket() {
        let (_c, ctx) = surface(8, 8);
        {
            let mut p = Canvas2dPainter::new(&ctx);
            p.push_group(0.5, BlendMode::Normal);
            p.push_isolated_layer(0.5, BlendMode::Normal);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 8.0 },
                        &Brush::Solid(Color::rgb(1.0, 0.0, 0.0)), 1.0);
            p.push_mask_layer(Mask::LuminanceClipIn);
            white(&mut p, 0.0, 8.0);
            p.pop_mask_layer();
            p.pop_isolated_layer();
            p.pop_group();
        }
        // 0.5 × 0.5 = 0.25 → 64, each factor exactly once, mask fully opaque.
        let a = alpha_at(&ctx, 4.0, 4.0);
        assert!((a as i32 - 64).abs() <= 1,
                "group 0.5 × layer 0.5 with a full mask must be ~64, got {a}");
    }

    /// ⛔ NESTING (§3.5 / D-β): a mask bracket inside a layer inside a layer.
    /// The inner mask must clip the INNER layer only — if the surfaces were
    /// shared, the outer layer's body would be clipped too and the right half
    /// would come back empty.
    #[wasm_bindgen_test]
    fn an_inner_masks_bracket_does_not_clip_the_outer_layer() {
        let (_c, ctx) = surface(8, 8);
        {
            let mut p = Canvas2dPainter::new(&ctx);
            p.push_isolated_layer(1.0, BlendMode::Normal);
            // outer body: the RIGHT half
            p.fill_rect(Rect { x: 4.0, y: 0.0, w: 4.0, h: 8.0 },
                        &Brush::Solid(Color::rgb(0.0, 1.0, 0.0)), 1.0);
            p.push_isolated_layer(1.0, BlendMode::Normal);
            // inner body: the LEFT half, fully masked away
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 8.0 },
                        &Brush::Solid(Color::rgb(0.0, 0.0, 1.0)), 1.0);
            p.push_mask_layer(Mask::LuminanceClipIn);
            black(&mut p, 0.0, 8.0);   // luminance 0 → cut everything
            p.pop_mask_layer();
            p.pop_isolated_layer();
            p.pop_isolated_layer();
        }
        assert_eq!(alpha_at(&ctx, 1.0, 4.0), 0, "the inner layer was masked away");
        assert_eq!(alpha_at(&ctx, 6.0, 4.0), 255,
                   "the OUTER layer's body must survive — a shared scratch \
                    surface would have clipped it too (D-β's shape)");
    }

    // ═══════════════════════════════════════════════════════════════════
    // F2 — THE CANVAS2D CORPUS-REPLAY DRIVER.
    //
    // ⛔ WHY IT EXISTS. `direct2d/replay.rs` drives EVERY recorded scene through
    // its backend and reports, per command, what it could not do. Canvas2D had
    // no such lane: it consumed the same JSON only as EXPECTED OUTPUT (a
    // RecordingPainter's text compared against the golden) and its browser
    // coverage was bespoke unit tests. So one backend's report was derived from
    // the fixtures and the other's did not exist — and anything built on that
    // asymmetry would be half-derived, which looks finished and is not.
    //
    // This drives the SAME ARTIFACT (painter::corpus::SCENES) through the SAME
    // trait, in a real browser.
    //
    // ⚠️ IT ASSERTS COVERAGE, NOT PIXELS. What a scene should LOOK like is the
    // goldens' job; what this says is that every recorded command EXECUTES here
    // — which is the fact a capability report would have to rest on, and the
    // fact nobody could state for this backend before.
    // ═══════════════════════════════════════════════════════════════════

    // ⛔ THE DISPATCH IS NO LONGER LOCAL TO THIS TEST. It lived here as a
    // private copy of `direct2d/replay.rs`'s loop, which meant the two
    // backends read the same ARTIFACT and ran two different DECODERS -- and a
    // capability answer measured by two loops is two measurements of two
    // things. `painter::replay_drive::drive` is the one dispatch; this lane
    // now differs from the native lane only in WHICH backend it drives.

    /// ⛔ EVERY RECORDED COMMAND IN THE WHOLE CORPUS EXECUTES ON THIS BACKEND.
    /// Not "the suite is green" — the count is read back and compared against
    /// what the corpus actually holds, so a command silently skipped makes the
    /// total fall short and names its scene.
    ///
    /// ⚖️ AND THE BACKEND'S STATED CAPABILITY ANSWERS ARE HELD AGAINST IT.
    /// `Canvas2dPainter::supports` answers YES to all three; this is where that
    /// claim is checked rather than trusted. A `supports` flipped to `false`
    /// while the backend keeps executing the ops reds here (a false no), and a
    /// backend that starts refusing an op it claims reds here too (a false yes).
    #[wasm_bindgen_test]
    fn every_recorded_scene_replays_through_canvas2d() {
        use crate::painter::replay_drive::{assert_answers_match_the_corpus, drive};

        let mut total = 0usize;
        let mut executed = 0usize;
        let mut per_scene = Vec::new();
        for (name, text) in crate::painter::corpus::SCENES {
            let scene: serde_json::Value =
                serde_json::from_str(text).expect("corpus scene must parse");
            let ops = scene.as_array().expect("a scene is an array").clone();
            // A fresh surface per scene: leftover context state from a previous
            // scene would make this measure the ORDER as well as the ops.
            let (_c, ctx) = surface(64, 64);
            let mut p = Canvas2dPainter::new(&ctx);
            let r = drive(&mut p, &ops);
            assert!(
                r.refused.is_empty(),
                "{name}: {:?} refused -- a command this backend cannot replay is \
                 a GAP, and it must be named, not absorbed",
                r.refused
            );
            assert_eq!(r.executed, ops.len(), "{name}: executed {} of {}", r.executed, ops.len());
            total += ops.len();
            executed += r.executed;
            per_scene.push((*name, ops, r.refused));
        }
        // ANTI-VACUITY: an empty corpus would satisfy every assertion above.
        assert!(crate::painter::corpus::SCENES.len() >= 20,
                "the corpus shrank; this lane replays whatever it is given");
        assert!(total >= 124, "corpus op count fell to {total}");
        assert_eq!(executed, total);

        // ⛔ ASKED THROUGH `Caps::of`, NOT A HAND-WRITTEN MATCH. The first cut
        // listed the variants here and paid for it within the day: widening the
        // blend capability broke THIS browser-only line, which no native run
        // compiles. `Caps::of` walks `Capability::ALL`, so a vocabulary change
        // needs no edit in a lane that cannot tell you it is broken.
        let probe = {
            let (_c, ctx) = surface(1, 1);
            let p = Canvas2dPainter::new(&ctx);
            Caps::of(&p)
        };
        assert_answers_match_the_corpus(&|c: Capability| probe.has(c), &per_scene);
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// THE PRIMITIVE PIXEL LAWS — the "no pixel can fail" census, closed.
//
// ⛔ WHY THESE EXIST, AND IT IS A MEASUREMENT, NOT A HUNCH. 2026-09-02: every
// backend-local decision in this file was driven as a mutant through the whole
// browser lane, because a display-list golden (`RecordingPainter`, R4) pins what
// commands CROSS the seam and cannot see what this backend does with them — so
// a decision below the seam has exactly one possible witness, a browser pixel
// test. 24 mutants driven, **19 SURVIVED**: the entire primitive layer of this
// backend — gradients, stroke width, dash, cap, join, miter, the winding rule,
// curve construction, close-path, the group alpha product, the group blend, the
// translucent-colour form — could be broken without one test going red.
//
// The 15 arms above are all A6: layers and masks. The corpus replay lane says so
// itself ("⚠️ IT ASSERTS COVERAGE, NOT PIXELS"): all 21 recorded scenes execute
// on this backend in a real browser and NOT ONE PIXEL of them is read. That is
// the shape the census found — a lane that runs everything and observes nothing.
//
// Each arm below names the mutant it kills. Two things it deliberately does NOT
// do, both recorded rather than papered over:
//
//   * **The ellipse arc's generality is not pinned, because nothing produces
//     it.** `rotation`, `ccw` and a partial sweep survived as mutants, and the
//     reason is measured, not assumed: production emits only
//     `EllipseArc::ellipse(..)` (element_render.rs:517, :858, :1109) and EVERY
//     arc in the whole recorded corpus is `rotation 0, start 0, end 6.2832,
//     ccw false`. A fixture for a shape neither production nor the corpus can
//     take is green forever and reads as coverage. ⚠️ It does leave one real
//     cross-port question open, stated as a negative: `Direct2DPainter` pins
//     `a_partial_arc_paints_nothing_rather_than_a_full_ellipse` while this
//     backend would draw the arc — a DIVERGENCE that no gate can see today
//     precisely because no producer emits a partial arc.
//   * **`draw_text_run` is not pinned, because it is unreachable.**
//     `element_needs_legacy` returns true for Text/TextPath so the web walk
//     never routes text here, and `first_unpaintable` refuses any document
//     carrying it on the native walk. Its `letter_spacing` is elided in the body
//     with a comment saying so. Two mutants (size, baseline anchor) survived and
//     STAY survived, recorded here.
// ═══════════════════════════════════════════════════════════════════════════
#[cfg(all(test, target_arch = "wasm32"))]
mod primitive_pixel_laws {
    use super::browser_probe::{alpha_at, rgba_at, surface};
    use super::*;
    use crate::painter::ColorStop;
    use wasm_bindgen_test::*;

    wasm_bindgen_test_configure!(run_in_browser);

    fn red() -> Color {
        Color::rgb(1.0, 0.0, 0.0)
    }
    fn blue() -> Color {
        Color::rgb(0.0, 0.0, 1.0)
    }
    fn stroke(width: f64, cap: LineCap, join: LineJoin, miter: f64, dash: Vec<f64>) -> StrokeStyle {
        StrokeStyle { width, cap, join, miter, dash }
    }
    fn line(pts: &[(f64, f64)]) -> Vec<PathCommand> {
        let mut v = vec![PathCommand::MoveTo { x: pts[0].0, y: pts[0].1 }];
        for (x, y) in &pts[1..] {
            v.push(PathCommand::LineTo { x: *x, y: *y });
        }
        v
    }

    /// ⛔ A LINEAR GRADIENT'S ENDPOINTS ARRIVE RESOLVED AND MUST BE PLOTTED THE
    /// WAY ROUND THEY ARRIVED (contract R3: the build site owns `angle`, the
    /// backend owns nothing but the geometry).
    ///
    /// Kills `linear_gradient_endpoints_are_swapped`, which survived the whole
    /// lane: `create_linear_gradient(x1, y1, x0, y0)` reverses every gradient in
    /// the application and no test could tell.
    #[wasm_bindgen_test]
    fn a_linear_gradients_first_stop_lands_at_the_end_it_was_given() {
        let (_c, ctx) = surface(16, 4);
        {
            let mut p = Canvas2dPainter::new(&ctx);
            p.fill_rect(
                Rect { x: 0.0, y: 0.0, w: 16.0, h: 4.0 },
                &Brush::Linear(LinearGradient {
                    x0: 0.0,
                    y0: 0.0,
                    x1: 16.0,
                    y1: 0.0,
                    stops: vec![
                        ColorStop { offset: 0.0, color: red() },
                        ColorStop { offset: 1.0, color: blue() },
                    ],
                }),
                1.0,
            );
        }
        let l = rgba_at(&ctx, 0.0, 2.0);
        let r = rgba_at(&ctx, 15.0, 2.0);
        assert!(l.0 > 200 && l.2 < 60, "stop 0 (red) belongs at (x0,y0); got {l:?}");
        assert!(r.2 > 200 && r.0 < 60, "stop 1 (blue) belongs at (x1,y1); got {r:?}");
    }

    /// ⛔ A RADIAL GRADIENT'S INNER CIRCLE IS THE ONE THE FIRST STOP PAINTS.
    /// Production always builds the concentric `r0 = 0` case
    /// (`element_render::resolve_gradient`), so swapping the radii puts the
    /// far-end colour at the centre of every radial fill in the application.
    ///
    /// Kills `radial_gradient_radii_are_swapped`.
    #[wasm_bindgen_test]
    fn a_radial_gradients_first_stop_is_at_its_inner_circle() {
        let (_c, ctx) = surface(32, 32);
        {
            let mut p = Canvas2dPainter::new(&ctx);
            p.fill_rect(
                Rect { x: 0.0, y: 0.0, w: 32.0, h: 32.0 },
                &Brush::Radial(RadialGradient {
                    x0: 16.0,
                    y0: 16.0,
                    r0: 0.0,
                    x1: 16.0,
                    y1: 16.0,
                    r1: 16.0,
                    stops: vec![
                        ColorStop { offset: 0.0, color: red() },
                        ColorStop { offset: 1.0, color: blue() },
                    ],
                }),
                1.0,
            );
        }
        let centre = rgba_at(&ctx, 16.0, 16.0);
        let edge = rgba_at(&ctx, 16.0, 31.0);
        assert!(centre.0 > 200 && centre.2 < 60, "the r0 end is the centre; got {centre:?}");
        assert!(edge.2 > 200 && edge.0 < 60, "the r1 end is the rim; got {edge:?}");
    }

    /// ⛔ A STROKE IS AS WIDE AS THE STYLE SAYS. Kills `stroke_width_is_ignored`
    /// (`set_line_width(1.0)`), which survived: every stroke in the application
    /// could collapse to a hairline with the lane green.
    #[wasm_bindgen_test]
    fn a_stroke_is_as_wide_as_the_style_asked_for() {
        let (_c, ctx) = surface(16, 16);
        {
            let mut p = Canvas2dPainter::new(&ctx);
            p.stroke_path(
                &line(&[(2.0, 8.0), (14.0, 8.0)]),
                &Brush::Solid(Color::WHITE),
                &stroke(6.0, LineCap::Butt, LineJoin::Miter, 10.0, Vec::new()),
                1.0,
            );
        }
        // A 6-wide stroke centred on y = 8 covers y ∈ [5, 11].
        assert!(alpha_at(&ctx, 8.0, 6.0) > 200, "y=6 is inside a 6-wide stroke");
        assert_eq!(alpha_at(&ctx, 8.0, 13.0), 0, "y=13 is outside it");
    }

    /// ⛔ THE MITER LIMIT REACHES THE CONTEXT. Two arms, ONE VARIABLE: the same
    /// path, width and join, differing only in `miter`. The corner's miter ratio
    /// is ~16, so a limit of 20 keeps the spike and a limit of 2 bevels it away.
    ///
    /// Kills `miter_limit_is_ignored` (`set_miter_limit(10.0)`, the CSS default),
    /// under which BOTH arms bevel and the first assertion fails.
    #[wasm_bindgen_test]
    fn the_miter_limit_decides_whether_a_sharp_corner_keeps_its_spike() {
        // Apex at (100, 32); each leg rises 6 over 96, so the half-angle is
        // atan(6/96) = 3.576° and the miter ratio is 1/sin(3.576°) ≈ 16.0.
        let path = line(&[(4.0, 26.0), (100.0, 32.0), (4.0, 38.0)]);
        let probe = |miter: f64| -> u8 {
            let (_c, ctx) = surface(128, 64);
            {
                let mut p = Canvas2dPainter::new(&ctx);
                p.stroke_path(
                    &path,
                    &Brush::Solid(Color::WHITE),
                    &stroke(3.0, LineCap::Butt, LineJoin::Miter, miter, Vec::new()),
                    1.0,
                );
            }
            // 6px past the apex, on the bisector. The outer miter tip sits
            // (w/2)/sin(3.576°) ≈ 24px past the apex, so the wedge is still
            // ~2.2px thick here — thick enough that the probed pixel is FULLY
            // covered, which is what keeps this arm off an antialiasing edge.
            // A bevel leaves nothing at all past the apex.
            alpha_at(&ctx, 106.0, 32.0)
        };
        assert!(probe(20.0) > 200, "a limit above the corner's ratio keeps the miter");
        assert_eq!(probe(2.0), 0, "a limit below it bevels the corner away");
    }

    /// ⛔ THE DASH PATTERN REACHES THE CONTEXT. Kills
    /// `dash_pattern_is_never_set`, under which every dashed stroke in the
    /// application draws solid.
    #[wasm_bindgen_test]
    fn a_dashed_stroke_leaves_the_gaps_its_pattern_asks_for() {
        let (_c, ctx) = surface(24, 8);
        {
            let mut p = Canvas2dPainter::new(&ctx);
            p.stroke_path(
                &line(&[(0.0, 4.0), (24.0, 4.0)]),
                &Brush::Solid(Color::WHITE),
                &stroke(4.0, LineCap::Butt, LineJoin::Miter, 10.0, vec![4.0, 4.0]),
                1.0,
            );
        }
        assert!(alpha_at(&ctx, 2.0, 4.0) > 200, "x=2 is inside the first dash");
        assert_eq!(alpha_at(&ctx, 6.0, 4.0), 0, "x=6 is inside the first gap");
        assert!(alpha_at(&ctx, 10.0, 4.0) > 200, "x=10 is inside the second dash");
    }

    /// ⛔ THE LINE CAP REACHES THE CONTEXT, AND ALL THREE VALUES DIFFER.
    /// Kills `line_cap_collapses_to_butt`.
    ///
    /// The segment ends at x = 12 with width 8, so a butt cap stops there, a
    /// round cap adds a half-disc of radius 4, and a square cap adds a 4-deep
    /// box. `(13, 8)` separates butt from the other two; `(15, 11)` — 4.24 from
    /// the end point, just outside the disc — separates round from square.
    #[wasm_bindgen_test]
    fn each_line_cap_paints_its_own_shape_past_the_end_point() {
        let probe = |cap: LineCap, x: f64, y: f64| -> u8 {
            let (_c, ctx) = surface(24, 24);
            {
                let mut p = Canvas2dPainter::new(&ctx);
                p.stroke_path(
                    &line(&[(4.0, 8.0), (12.0, 8.0)]),
                    &Brush::Solid(Color::WHITE),
                    &stroke(8.0, cap, LineJoin::Miter, 10.0, Vec::new()),
                    1.0,
                );
            }
            alpha_at(&ctx, x, y)
        };
        assert_eq!(probe(LineCap::Butt, 13.0, 8.0), 0, "butt stops at the end point");
        assert!(probe(LineCap::Round, 13.0, 8.0) > 200, "round reaches past it");
        assert!(probe(LineCap::Square, 13.0, 8.0) > 200, "square reaches past it");
        assert_eq!(probe(LineCap::Round, 15.0, 11.0), 0, "the round cap is a disc");
        assert!(probe(LineCap::Square, 15.0, 11.0) > 200, "the square cap is a box");
    }

    /// ⛔ THE LINE JOIN REACHES THE CONTEXT, AND ALL THREE VALUES DIFFER.
    /// Kills `line_join_collapses_to_miter`.
    ///
    /// A right-angle corner at (8, 8) with width 16 puts the outer corner at
    /// (0, 0). Miter fills the square corner; round fills the quarter-disc of
    /// radius 8; bevel fills only the triangle `x + y ≥ 8`. `(1, 1)` is inside
    /// the miter and outside both others; `(3, 3)` is inside the round and
    /// outside the bevel — so the two probes separate all three, with ≥ 0.9px
    /// of margin at every boundary.
    #[wasm_bindgen_test]
    fn each_line_join_paints_its_own_shape_at_the_outer_corner() {
        let probe = |join: LineJoin, x: f64, y: f64| -> u8 {
            let (_c, ctx) = surface(48, 48);
            {
                let mut p = Canvas2dPainter::new(&ctx);
                p.stroke_path(
                    &line(&[(8.0, 40.0), (8.0, 8.0), (40.0, 8.0)]),
                    &Brush::Solid(Color::WHITE),
                    &stroke(16.0, LineCap::Butt, join, 10.0, Vec::new()),
                    1.0,
                );
            }
            alpha_at(&ctx, x, y)
        };
        assert!(probe(LineJoin::Miter, 1.0, 1.0) > 200, "the miter fills the corner");
        assert_eq!(probe(LineJoin::Round, 1.0, 1.0), 0, "the round join is a disc of radius 8");
        assert_eq!(probe(LineJoin::Bevel, 1.0, 1.0), 0, "the bevel cuts the corner off");
        assert!(probe(LineJoin::Round, 3.0, 3.0) > 200, "3,3 is inside the disc");
        assert_eq!(probe(LineJoin::Bevel, 3.0, 3.0), 0, "3,3 is outside the bevel triangle");
    }

    /// ⛔ A QUADRATIC SEGMENT IS A CURVE, NOT ITS CHORD. Kills
    /// `quad_to_degrades_to_a_line` — under which the shape below collapses to a
    /// zero-area sliver and paints nothing at all.
    #[wasm_bindgen_test]
    fn a_quadratic_segment_bulges_away_from_its_chord() {
        let (_c, ctx) = surface(40, 40);
        {
            let mut p = Canvas2dPainter::new(&ctx);
            // Control (20, -10) puts the curve's apex at (20, 10); the closing
            // line runs along y = 30.
            let path = vec![
                PathCommand::MoveTo { x: 2.0, y: 30.0 },
                PathCommand::QuadTo { x1: 20.0, y1: -10.0, x: 38.0, y: 30.0 },
                PathCommand::ClosePath,
            ];
            p.fill_path(&path, FillRule::NonZero, &Brush::Solid(Color::WHITE), 1.0);
        }
        assert!(alpha_at(&ctx, 20.0, 20.0) > 200, "the curve encloses (20,20)");
        assert_eq!(alpha_at(&ctx, 20.0, 5.0), 0, "and does not reach (20,5)");
    }

    /// ⛔ `ClosePath` CLOSES THE FIGURE FOR A STROKE. A fill closes each subpath
    /// implicitly, so only a STROKE can observe this at all — which is why the
    /// mutant `close_path_is_dropped` survived a lane holding 21 recorded scenes.
    #[wasm_bindgen_test]
    fn close_path_strokes_the_edge_back_to_the_start() {
        let (_c, ctx) = surface(48, 48);
        {
            let mut p = Canvas2dPainter::new(&ctx);
            let mut path = line(&[(8.0, 8.0), (40.0, 8.0), (24.0, 36.0)]);
            path.push(PathCommand::ClosePath);
            p.stroke_path(
                &path,
                &Brush::Solid(Color::WHITE),
                &stroke(6.0, LineCap::Butt, LineJoin::Miter, 10.0, Vec::new()),
                1.0,
            );
        }
        // The midpoint of the CLOSING edge (24,36)→(8,8); 13.9px from the
        // nearest other edge, so nothing else can paint it.
        assert!(alpha_at(&ctx, 16.0, 22.0) > 200, "the closing edge is stroked");
    }

    /// ⛔ THE WINDING RULE REACHES THE CONTEXT (AMENDMENT A3). Two nested
    /// squares of the SAME orientation: even-odd leaves the middle empty,
    /// non-zero fills it solid. Kills `even_odd_winding_becomes_non_zero`, under
    /// which every boolean-op result with a hole fills solid — and the
    /// even-odd clip that `emit_path_stroke` builds for an outside stroke stops
    /// being a ring.
    #[wasm_bindgen_test]
    fn the_even_odd_rule_leaves_the_hole_that_non_zero_fills() {
        let path = {
            let mut v = line(&[(4.0, 4.0), (44.0, 4.0), (44.0, 44.0), (4.0, 44.0)]);
            v.push(PathCommand::ClosePath);
            v.extend(line(&[(16.0, 16.0), (32.0, 16.0), (32.0, 32.0), (16.0, 32.0)]));
            v.push(PathCommand::ClosePath);
            v
        };
        let probe = |rule: FillRule, x: f64, y: f64| -> u8 {
            let (_c, ctx) = surface(48, 48);
            {
                let mut p = Canvas2dPainter::new(&ctx);
                p.fill_path(&path, rule, &Brush::Solid(Color::WHITE), 1.0);
            }
            alpha_at(&ctx, x, y)
        };
        assert!(probe(FillRule::NonZero, 24.0, 24.0) > 200, "non-zero fills the middle");
        assert_eq!(probe(FillRule::EvenOdd, 24.0, 24.0), 0, "even-odd leaves the hole");
        assert!(probe(FillRule::EvenOdd, 8.0, 24.0) > 200, "and still fills the ring");
    }

    /// ⛔ A TRANSLUCENT COLOUR CROSSES AS `rgba(...)`, NOT `rgb(...)`. Kills
    /// `css_colour_drops_the_alpha_form`, which survived: gradient stops carry
    /// their opacity BAKED INTO THE STOP COLOUR
    /// (`element_render::resolve_gradient` folds `stop.opacity` in), so this is
    /// the only carrier a partly-transparent stop has.
    #[wasm_bindgen_test]
    fn a_translucent_colour_keeps_its_alpha_across_the_lowering() {
        let (_c, ctx) = surface(8, 8);
        {
            let mut p = Canvas2dPainter::new(&ctx);
            p.fill_rect(
                Rect { x: 0.0, y: 0.0, w: 8.0, h: 8.0 },
                &Brush::Solid(Color::WHITE.with_alpha(0.5)),
                1.0,
            );
        }
        let a = alpha_at(&ctx, 4.0, 4.0);
        assert!((120..=136).contains(&a), "a 0.5-alpha colour must land near 128, got {a}");
    }

    /// ⛔ THE OPEN-GROUP PRODUCT MULTIPLIES INTO EVERY PAINT, AND OVERLAPS
    /// COMPOUND (contract D3 — `push_group` is NON-isolated, so the second fill
    /// composites against the first). Kills `group_alpha_product_is_ignored`.
    ///
    /// ⚖️ THIS IS A PARITY ARM. `Direct2DPainter` has pinned exactly this in
    /// pixels since B1 (`group_alphas_multiply_and_nest`,
    /// `overlapping_fills_in_a_group_compound_rather_than_isolate`) and this
    /// backend had nothing — the census found the two ports' pixel coverage
    /// nearly DISJOINT, which is the one thing exact functional equivalence
    /// cannot survive.
    #[wasm_bindgen_test]
    fn the_open_group_alphas_multiply_into_a_paint_and_overlaps_compound() {
        let (_c, ctx) = surface(16, 8);
        {
            let mut p = Canvas2dPainter::new(&ctx);
            p.push_group(0.5, BlendMode::Normal);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 8.0 }, &Brush::Solid(Color::WHITE), 1.0);
            p.push_group(0.5, BlendMode::Normal);
            p.fill_rect(Rect { x: 8.0, y: 0.0, w: 8.0, h: 8.0 }, &Brush::Solid(Color::WHITE), 1.0);
            p.pop_group();
            // The overlap: a SECOND paint at 0.5 over the first, non-isolated.
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 8.0 }, &Brush::Solid(Color::WHITE), 1.0);
            p.pop_group();
        }
        let nested = alpha_at(&ctx, 12.0, 4.0);
        assert!((60..=68).contains(&nested), "0.5 × 0.5 must land near 64, got {nested}");
        let compounded = alpha_at(&ctx, 4.0, 4.0);
        assert!(
            (188..=196).contains(&compounded),
            "two 0.5 paints must compound to 0.75 (≈191), not isolate to 128; got {compounded}"
        );
    }

    /// ⛔ A GROUP'S BLEND MODE REACHES THE CONTEXT. Kills
    /// `group_blend_never_reaches_the_context` AND the mutant that mis-mapped
    /// one row of the blend table.
    ///
    /// ⚠️ SAID AS A NEGATIVE: `push_group` has NO PRODUCTION CALLER today —
    /// `emit_element` folds group alpha and emits none (D3), so the only
    /// producers are the recorded corpus (`group_blend.json`) and this file.
    /// The arm is written anyway because the corpus DOES drive it through this
    /// backend and read nothing, and because the op is part of the frozen
    /// contract both ports implement.
    #[wasm_bindgen_test]
    fn a_groups_blend_mode_reaches_the_primitives_inside_it() {
        let (_c, ctx) = surface(8, 8);
        {
            let mut p = Canvas2dPainter::new(&ctx);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 8.0 }, &Brush::Solid(red()), 1.0);
            p.push_group(1.0, BlendMode::Multiply);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 8.0 }, &Brush::Solid(blue()), 1.0);
            p.pop_group();
        }
        // multiply(red, blue) = black; source-over would leave blue, and the
        // mis-mapped table would screen them to magenta.
        let px = rgba_at(&ctx, 4.0, 4.0);
        assert_eq!((px.0, px.1, px.2), (0, 0, 0), "multiply of red and blue is black; got {px:?}");
        assert_eq!(px.3, 255, "and it is opaque");
    }
}
