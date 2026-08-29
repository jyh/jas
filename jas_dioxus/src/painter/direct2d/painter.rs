//! `Direct2DPainter` — the ratified 14-method seam, on Direct2D.
//!
//! B1 concluded PROCEED: every method lands on a named interface. This is the
//! unblocked part. Two capabilities are deliberately absent and say so loudly
//! rather than drawing something plausible:
//!
//!   * **masks** — `push_mask_layer`/`pop_mask_layer`. Blocked on the ELEMENT
//!     BRACKET ruling (JYH ruled option C, 2026-07-30; design with Starbuck).
//!     `Mask` carries only the law, and no frozen op opens the isolated
//!     element-body buffer a mask must eat into. B1 also established that
//!     `D2D1_LAYER_PARAMETERS1` serves NONE of the three variants, so this is
//!     not a case of "wire up the obvious layer call".
//!   * **the 15 non-Normal blend modes** — they need a backdrop snapshot plus a
//!     `CLSID_D2D1Blend` effect graph per blended primitive, and B1 found blend
//!     does not currently reach the seam in production at all.
//!
//! GROUP ALPHA IS FREE AND MUST STAY FREE. `push_group` is documented
//! non-isolated ("No offscreen is allocated"). The contract's own reading —
//! confirmed by B1 — is an owned multiply stack: effective alpha is
//! `product(open group alphas) * paint_alpha`, and overlaps COMPOUND because it
//! is one flat multiply. A `PushLayer` here would isolate and stop overlaps
//! compounding, i.e. would be WRONG. There is a test for that below.

use windows::core::Result;
use windows::Win32::Graphics::Direct2D::Common::{
    D2D1_COLOR_F, D2D1_GRADIENT_STOP, D2D_RECT_F,
};
use windows::Win32::Graphics::Direct2D::{
    ID2D1Brush, ID2D1RenderTarget, ID2D1SolidColorBrush, ID2D1StrokeStyle,
    D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, D2D1_ELLIPSE, D2D1_EXTEND_MODE_CLAMP,
    D2D1_GAMMA_2_2, D2D1_LAYER_OPTIONS_NONE, D2D1_LAYER_PARAMETERS,
    D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES, D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES,
};
use windows_numerics::Matrix3x2;

use super::{convert, geometry, text};
use crate::geometry::element::Color;
use crate::painter::{
    BlendMode, Brush, EllipseArc, FillRule, Mask, Painter, PathCommand, Rect, StrokeStyle,
    TextRun, Transform,
};

/// What a `pop_state` has to undo, in strict LIFO order. D2D has no
/// canvas-style save/restore stack: `SaveDrawingState` needs a whole
/// `ID2D1DrawingStateBlock` per save, and clips must be popped by the exact
/// call that pushed them. Mixing `PopLayer` and `PopAxisAlignedClip` is legal
/// but ONLY in reverse order, and `PushAxisAlignedClip` returns no error code —
/// a mismatch surfaces as a failed `EndDraw`, far from its cause.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pop {
    Layer,
    AxisAlignedClip,
}

struct Frame {
    transform: Matrix3x2,
    opened: Vec<Pop>,
}

pub struct Direct2DPainter<'a> {
    rt: &'a ID2D1RenderTarget,
    frames: Vec<Frame>,
    /// The owned multiply stack. See the module note: NOT a layer.
    group_alphas: Vec<f64>,
}

impl<'a> Direct2DPainter<'a> {
    pub fn new(rt: &'a ID2D1RenderTarget) -> Self {
        Self { rt, frames: Vec::new(), group_alphas: Vec::new() }
    }

    /// `product(open group alphas) * paint_alpha`, clamped. This is the whole
    /// of group alpha and it is why no offscreen is needed.
    pub fn effective_alpha(&self, paint_alpha: f64) -> f64 {
        let p: f64 = self.group_alphas.iter().product::<f64>() * paint_alpha;
        p.clamp(0.0, 1.0)
    }

    fn solid(&self, c: Color, alpha: f64) -> Result<ID2D1SolidColorBrush> {
        // to_rgba() is the canonical accessor -- Color is an enum over
        // Rgb/Hsb/Cmyk and canvas2d.rs goes through the same call, so both
        // backends see identical numbers rather than each converting.
        let (r, g, b, a) = c.to_rgba();
        let col = D2D1_COLOR_F {
            r: r as f32,
            g: g as f32,
            b: b as f32,
            // The contract's Color carries its own alpha; the effective paint
            // alpha MULTIPLIES it rather than replacing it.
            a: (a * alpha) as f32,
        };
        unsafe { self.rt.CreateSolidColorBrush(&col, None) }
    }

    /// GAMMA_2_2, NOT GAMMA_1_0 -- a divergence pin, not a default.
    ///
    /// CSS gradients interpolate in sRGB (gamma-encoded) space. D2D's
    /// `D2D1_GAMMA_1_0` interpolates LINEARLY, which is a different and visibly
    /// lighter midpoint on any two-stop gradient. Nothing in the corpus compares
    /// gradient pixels, so picking the wrong one would never go red.
    fn stops(&self, stops: &[crate::painter::ColorStop], alpha: f64)
        -> Option<windows::Win32::Graphics::Direct2D::ID2D1GradientStopCollection>
    {
        let v: Vec<D2D1_GRADIENT_STOP> = stops.iter().map(|s| {
            let (r, g, b, a) = s.color.to_rgba();
            D2D1_GRADIENT_STOP {
                position: s.offset as f32,
                color: D2D1_COLOR_F { r: r as f32, g: g as f32, b: b as f32, a: (a * alpha) as f32 },
            }
        }).collect();
        unsafe { self.rt.CreateGradientStopCollection(&v, D2D1_GAMMA_2_2, D2D1_EXTEND_MODE_CLAMP) }.ok()
    }

    fn brush(&self, b: &Brush, alpha: f64) -> Option<ID2D1Brush> {
        match b {
            Brush::Solid(c) => self.solid(*c, alpha).ok().map(|s| s.into()),
            Brush::Linear(g) => {
                let sc = self.stops(&g.stops, alpha)?;
                let props = D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES {
                    startPoint: windows_numerics::Vector2 { X: g.x0 as f32, Y: g.y0 as f32 },
                    endPoint: windows_numerics::Vector2 { X: g.x1 as f32, Y: g.y1 as f32 },
                };
                unsafe { self.rt.CreateLinearGradientBrush(&props, None, &sc) }.ok().map(|b| b.into())
            }
            Brush::Radial(g) => {
                // D2D radial is ONE circle plus an origin offset; the contract
                // (like canvas createRadialGradient) is TWO circles. They
                // coincide only when the inner radius is 0. Refuse otherwise
                // rather than drawing a plausible-but-wrong gradient -- every
                // radial in the corpus has r0 = 0.
                if g.r0 != 0.0 {
                    return None;
                }
                let sc = self.stops(&g.stops, alpha)?;
                let props = D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES {
                    center: windows_numerics::Vector2 { X: g.x1 as f32, Y: g.y1 as f32 },
                    gradientOriginOffset: windows_numerics::Vector2 {
                        X: (g.x0 - g.x1) as f32, Y: (g.y0 - g.y1) as f32,
                    },
                    radiusX: g.r1 as f32,
                    radiusY: g.r1 as f32,
                };
                unsafe { self.rt.CreateRadialGradientBrush(&props, None, &sc) }.ok().map(|b| b.into())
            }
        }
    }

    fn stroke_style(&self, s: &StrokeStyle, emit_width: f64) -> Option<ID2D1StrokeStyle> {
        let props = convert::stroke_properties(s);
        let dashes = convert::dash_multiples(&s.dash, emit_width);
        let factory = unsafe { self.rt.GetFactory() }.ok()?;
        unsafe {
            factory
                .CreateStrokeStyle(&props, if dashes.is_empty() { None } else { Some(&dashes) })
                .ok()
        }
    }
}

/// The ONLY ellipse form built here, and the measurement behind that.
///
/// B1's matrix called full axis-aligned "100% of today's traffic" and partial
/// arcs "emitted by no production call site and covered by no golden". I checked
/// the 14 recorded scenes: 11 arcs, ALL full sweep, none rotated, none ccw.
/// B1 confirmed.
///
/// (My first probe said the opposite. The corpus emits 4 decimal places, so a
/// full sweep records as 6.2832 against 2 pi = 6.283185 -- a 1.5e-5 gap that a
/// 1e-6 tolerance calls "partial". Comparing anything to this corpus needs the
/// corpus's own precision, not f64's. That applies to the replay harness too.)
///
/// A partial or rotated arc returns None rather than drawing a full ellipse:
/// silently closing an arc is exactly the "looks almost right" failure.
fn full_ellipse(a: &EllipseArc) -> Option<D2D1_ELLIPSE> {
    const TAU: f64 = std::f64::consts::TAU;
    // Match the corpus's 4-decimal emission, not f64 precision.
    let full = (a.end - a.start).abs();
    if (full - TAU).abs() > 5e-5 || a.rotation != 0.0 {
        return None;
    }
    Some(D2D1_ELLIPSE {
        point: windows_numerics::Vector2 { X: a.cx as f32, Y: a.cy as f32 },
        radiusX: a.rx as f32,
        radiusY: a.ry as f32,
    })
}

fn d2d_rect(r: Rect) -> D2D_RECT_F {
    D2D_RECT_F { left: r.x as f32, top: r.y as f32, right: (r.x + r.w) as f32, bottom: (r.y + r.h) as f32 }
}

impl<'a> Painter for Direct2DPainter<'a> {
    /// ⚖️ THIS BACKEND ANSWERS NO — TO ALL THREE, AND THE FOUR
    /// `unimplemented!()` BODIES BELOW ARE WHY.
    ///
    /// * `IsolatedLayers` — `push_isolated_layer`/`pop_isolated_layer` panic;
    /// * `MaskLayers` — `push_mask_layer`/`pop_mask_layer` panic;
    /// * `NonNormalGroupBlend` — `push_group` takes a `BlendMode` and this
    ///   backend has no effect graph for the 15 non-Normal modes (B1: a
    ///   backdrop snapshot plus a `CLSID_D2D1Blend` graph per primitive, not
    ///   built). The replay harness has always reported this as a declared gap.
    ///
    /// ⇒ A masked or layered element STAYS LEGACY-ROUTED on Direct2D. That is
    /// the whole point of the query: the router can now be flipped for the
    /// backend that can do the work WITHOUT flipping it for the one that
    /// cannot, and neither answer is a comment — `replay.rs`'s corpus lane
    /// cross-checks this against what the backend actually refuses.
    ///
    /// This answer flips to `true` when (a) lands — D2D's mask + layer ops,
    /// flask's row, on B1's schedule. The ROUTER does not change then; this
    /// method does.
    fn supports(&self, _cap: crate::painter::capability::Capability) -> bool {
        false
    }

    fn fill_rect(&mut self, rect: Rect, brush: &Brush, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        if let Some(b) = self.brush(brush, a) {
            unsafe { self.rt.FillRectangle(&d2d_rect(rect), &b) };
        }
    }

    fn stroke_rect(&mut self, rect: Rect, brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        if let Some(b) = self.brush(brush, a) {
            let ss = self.stroke_style(stroke, stroke.width);
            unsafe {
                self.rt.DrawRectangle(&d2d_rect(rect), &b, stroke.width as f32, ss.as_ref())
            };
        }
    }

    fn push_state(&mut self, transform: Transform) {
        let cur = Matrix3x2 {
            M11: transform.a as f32, M12: transform.b as f32,
            M21: transform.c as f32, M22: transform.d as f32,
            M31: transform.e as f32, M32: transform.f as f32,
        };
        let mut prev = Matrix3x2::identity();
        unsafe { self.rt.GetTransform(&mut prev) };
        self.frames.push(Frame { transform: prev, opened: Vec::new() });
        unsafe { self.rt.SetTransform(&(cur * prev)) };
    }

    fn pop_state(&mut self) {
        if let Some(f) = self.frames.pop() {
            // STRICT LIFO. See the Pop note: a mismatch here surfaces as a
            // failed EndDraw far from its cause.
            for p in f.opened.iter().rev() {
                unsafe {
                    match p {
                        Pop::Layer => self.rt.PopLayer(),
                        Pop::AxisAlignedClip => self.rt.PopAxisAlignedClip(),
                    }
                }
            }
            unsafe { self.rt.SetTransform(&f.transform) };
        }
    }

    fn push_group(&mut self, alpha: f64, blend: BlendMode) {
        debug_assert!(
            matches!(blend, BlendMode::Normal),
            "non-Normal blend needs a backdrop snapshot + CLSID_D2D1Blend graph (B1); \
             not built, and blend does not reach the seam in production yet"
        );
        self.group_alphas.push(alpha);
    }

    fn pop_group(&mut self) {
        self.group_alphas.pop();
    }

    fn fill_path(&mut self, path: &[PathCommand], winding: FillRule, brush: &Brush, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        let Some(b) = self.brush(brush, a) else { return };
        let Ok(f) = (unsafe { self.rt.GetFactory() }) else { return };
        if let Ok(Some(g)) = geometry::build(&f, path, winding) {
            unsafe { self.rt.FillGeometry(&g, &b, None) };
        }
    }

    fn stroke_path(&mut self, path: &[PathCommand], brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        let Some(b) = self.brush(brush, a) else { return };
        let Ok(f) = (unsafe { self.rt.GetFactory() }) else { return };
        // A stroked path carries no fill rule; NonZero is the contract default
        // and the rule is irrelevant to stroking.
        if let Ok(Some(g)) = geometry::build(&f, path, FillRule::NonZero) {
            let ss = self.stroke_style(stroke, stroke.width);
            unsafe { self.rt.DrawGeometry(&g, &b, stroke.width as f32, ss.as_ref()) };
        }
    }

    fn fill_ellipse_arc(&mut self, arc: &EllipseArc, _winding: FillRule, brush: &Brush, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        let Some(b) = self.brush(brush, a) else { return };
        let Some(e) = full_ellipse(arc) else { return };
        unsafe { self.rt.FillEllipse(&e, &b) };
    }

    fn stroke_ellipse_arc(&mut self, arc: &EllipseArc, brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        let Some(b) = self.brush(brush, a) else { return };
        let Some(e) = full_ellipse(arc) else { return };
        let ss = self.stroke_style(stroke, stroke.width);
        unsafe { self.rt.DrawEllipse(&e, &b, stroke.width as f32, ss.as_ref()) };
    }

    /// NESTED, ARBITRARY-PATH CLIP. D2D has no cheap form: `PushAxisAlignedClip`
    /// takes rects only, so an arbitrary path needs a LAYER -- one offscreen
    /// clear, render and blend-back per call. B1 priced it and today's traffic
    /// is four call sites, all stroke-alignment, nesting depth 1.
    ///
    /// The contract has no `unclip`: a clip is undone by the enclosing
    /// `pop_state`, which is why the pop is recorded on the current frame.
    fn clip(&mut self, path: &[PathCommand], winding: FillRule) {
        let Ok(f) = (unsafe { self.rt.GetFactory() }) else { return };
        let Ok(Some(g)) = geometry::build(&f, path, winding) else { return };
        // D2D1_LAYER_PARAMETERS, not ...1: the v1 struct is what
        // ID2D1RenderTarget::PushLayer takes. The `1` variant belongs to
        // ID2D1DeviceContext, which the WIC target can be QueryInterface'd to
        // (B1 route (a)) -- needed for masks later, not for a geometric clip.
        let params = D2D1_LAYER_PARAMETERS {
            contentBounds: D2D_RECT_F { left: f32::MIN, top: f32::MIN, right: f32::MAX, bottom: f32::MAX },
            geometricMask: unsafe { std::mem::transmute_copy(&g) },
            maskAntialiasMode: D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
            maskTransform: Matrix3x2::identity(),
            opacity: 1.0,
            opacityBrush: std::mem::ManuallyDrop::new(None),
            layerOptions: D2D1_LAYER_OPTIONS_NONE,
        };
        unsafe { self.rt.PushLayer(&params, None) };
        // If no frame is open the clip lasts to EndDraw, which is the contract's
        // own shape -- record it only when there is a frame to unwind it.
        if let Some(fr) = self.frames.last_mut() {
            fr.opened.push(Pop::Layer);
        }
    }
    /// FastRun only. `PlacedGlyphs` is 2b's shape and no recorded scene uses
    /// it; refusing is honest rather than guessing an absolute-position mapping
    /// that nothing exercises.
    fn draw_text_run(&mut self, run: &TextRun, brush: &Brush, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        let Some(b) = self.brush(brush, a) else { return };
        match run {
            TextRun::FastRun { font, size, text: t, letter_spacing, x, y } => {
                text::draw_fast_run(self.rt, &b, font, *size, t, *letter_spacing, *x, *y);
            }
            _ => {}
        }
    }

    fn push_mask_layer(&mut self, _mask: Mask) {
        // ⛔ LEDGER RECONCILIATION (A6 item ④, 2026-08-27). This site cited
        // "option C, 2026-07-30" while the summons cited "option (a)". ONE
        // OBJECT, TWO LABELS — both were pre-ratification working names for the
        // element-bracket ruling, and they never disagreed on direction. The
        // ledger now carries ONE name: **AMENDMENT A6**, ratified 2026-08-27.
        // "option C (2026-07-30)" and "option (a)" are recorded here as its
        // prior labels so neither trail goes cold; neither is used again.
        unimplemented!(
            "masks are BLOCKED pending the A6 implementation (contract ratified \
             2026-08-27; prior labels: 'option C 2026-07-30' and 'option (a)'). A6 \
             adds push_isolated_layer/pop_isolated_layer, which opens the isolated \
             element-body buffer the law must eat into — the gap that blocked this \
             site is closed IN THE CONTRACT, not yet in this backend. B1 also \
             established D2D1_LAYER_PARAMETERS1 serves none of the three variants. \
             Do not wire a PushLayer here."
        )
    }
    fn pop_mask_layer(&mut self) {
        unimplemented!("see push_mask_layer")
    }

    fn push_isolated_layer(&mut self, _alpha: f64, _blend: BlendMode) {
        // A6 ratified the bracket; this backend does not yet implement it. B1's
        // finding stands: D2D1_LAYER_PARAMETERS1 serves none of the three mask
        // variants, so the layer target is a render-target swap, not a PushLayer.
        unimplemented!("A6 isolated layers are not yet implemented in the D2D backend")
    }

    fn pop_isolated_layer(&mut self) {
        unimplemented!("A6 isolated layers are not yet implemented in the D2D backend")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::painter::direct2d::device::HeadlessTarget;
    use crate::geometry::element::{LineCap, LineJoin};

    fn red() -> Brush {
        Brush::Solid(Color::new(1.0, 0.0, 0.0, 1.0))
    }

    /// Read one pixel as (b, g, r, a).
    fn px(buf: &[u8], w: u32, x: u32, y: u32) -> [u8; 4] {
        let i = ((y * w + x) * 4) as usize;
        [buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]
    }

    fn draw(w: u32, h: u32, f: impl FnOnce(&mut Direct2DPainter)) -> Vec<u8> {
        let t = HeadlessTarget::new(w, h).expect("target");
        unsafe {
            t.target().BeginDraw();
            t.target().Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 0.0 }));
            let mut p = Direct2DPainter::new(t.target());
            f(&mut p);
            t.target().EndDraw(None, None).expect("EndDraw");
        }
        t.read_bgra().expect("readback")
    }

    /// END TO END: a solid brush lands the right pixels at the right place.
    /// This is the first proof that brush, coordinate system and target all
    /// agree — every later test rests on it.
    #[test]
    fn fill_rect_lands_opaque_red_inside_and_nothing_outside() {
        let buf = draw(8, 8, |p| {
            p.fill_rect(Rect { x: 2.0, y: 2.0, w: 4.0, h: 4.0 }, &red(), 1.0);
        });
        // BGRA premultiplied: opaque red is [0,0,255,255].
        assert_eq!(px(&buf, 8, 4, 4), [0, 0, 255, 255], "inside");
        assert_eq!(px(&buf, 8, 0, 0), [0, 0, 0, 0], "outside stays clear");
        assert_eq!(px(&buf, 8, 7, 7), [0, 0, 0, 0], "outside stays clear");
    }

    /// paint_alpha reaches the pixels. Premultiplied, so a half-alpha red is
    /// [0,0,128,128]-ish rather than [0,0,255,128].
    #[test]
    fn paint_alpha_multiplies_into_the_brush() {
        let buf = draw(4, 4, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &red(), 0.5);
        });
        let [b, g, r, a] = px(&buf, 4, 1, 1);
        assert_eq!((b, g), (0, 0));
        assert!((a as i32 - 128).abs() <= 1, "alpha ~128, got {a}");
        assert!((r as i32 - 128).abs() <= 1, "premultiplied red ~128, got {r}");
    }

    /// GROUP ALPHA IS A MULTIPLY STACK, not a layer. Two nested 0.5 groups give
    /// 0.25, and this is arithmetic on the brush rather than an offscreen.
    #[test]
    fn group_alphas_multiply_and_nest() {
        let t = HeadlessTarget::new(2, 2).unwrap();
        let mut p = Direct2DPainter::new(t.target());
        assert_eq!(p.effective_alpha(1.0), 1.0);
        p.push_group(0.5, BlendMode::Normal);
        assert_eq!(p.effective_alpha(1.0), 0.5);
        p.push_group(0.5, BlendMode::Normal);
        assert_eq!(p.effective_alpha(1.0), 0.25);
        assert_eq!(p.effective_alpha(0.5), 0.125, "paint_alpha multiplies too");
        p.pop_group();
        assert_eq!(p.effective_alpha(1.0), 0.5);
        p.pop_group();
        assert_eq!(p.effective_alpha(1.0), 1.0);
    }

    /// The overlap property that makes a layer WRONG here: two half-alpha fills
    /// inside one group must COMPOUND, because it is a flat multiply with no
    /// isolation. An isolated layer would composite them once and give a
    /// different, lighter result.
    #[test]
    fn overlapping_fills_in_a_group_compound_rather_than_isolate() {
        let buf = draw(4, 4, |p| {
            p.push_group(0.5, BlendMode::Normal);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &red(), 1.0);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &red(), 1.0);
            p.pop_group();
        });
        let [_, _, _, a] = px(&buf, 4, 1, 1);
        // 0.5 over 0.5 = 0.75. Isolation would have produced 0.5.
        assert!((a as i32 - 191).abs() <= 2, "expected ~191 (0.75), got {a}");
    }

    #[test]
    fn push_state_restores_the_transform() {
        let t = HeadlessTarget::new(2, 2).unwrap();
        let mut p = Direct2DPainter::new(t.target());
        let ident = Transform { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 0.0, f: 0.0 };
        let shift = Transform { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 5.0, f: 7.0 };
        p.push_state(shift);
        let mut m = Matrix3x2::identity();
        unsafe { t.target().GetTransform(&mut m) };
        assert_eq!((m.M31, m.M32), (5.0, 7.0));
        p.pop_state();
        unsafe { t.target().GetTransform(&mut m) };
        assert_eq!((m.M31, m.M32), (0.0, 0.0), "pop_state restores");
        let _ = ident;
    }

    /// fill_path paints the interior of a closed triangle and nothing outside.
    #[test]
    fn fill_path_paints_a_triangle() {
        let buf = draw(16, 16, |p| {
            p.fill_path(&[
                PathCommand::MoveTo { x: 1.0, y: 1.0 },
                PathCommand::LineTo { x: 15.0, y: 1.0 },
                PathCommand::LineTo { x: 1.0, y: 15.0 },
                PathCommand::ClosePath,
            ], FillRule::NonZero, &red(), 1.0);
        });
        assert_eq!(px(&buf, 16, 3, 3), [0, 0, 255, 255], "well inside the triangle");
        assert_eq!(px(&buf, 16, 14, 14), [0, 0, 0, 0], "the cut-off corner stays clear");
    }

    /// A full-sweep ellipse fills. This is 100% of the recorded traffic.
    #[test]
    fn fill_ellipse_arc_paints_a_full_circle() {
        let arc = EllipseArc {
            cx: 8.0, cy: 8.0, rx: 6.0, ry: 6.0, rotation: 0.0,
            start: 0.0, end: std::f64::consts::TAU, ccw: false,
        };
        let buf = draw(16, 16, |p| p.fill_ellipse_arc(&arc, FillRule::NonZero, &red(), 1.0));
        assert_eq!(px(&buf, 16, 8, 8), [0, 0, 255, 255], "centre filled");
        assert_eq!(px(&buf, 16, 0, 0), [0, 0, 0, 0], "corner outside the circle");
    }

    /// THE REFUSAL THAT MATTERS MORE THAN THE DRAW. A partial arc must paint
    /// NOTHING rather than silently closing into a full ellipse -- an arc drawn
    /// as a disc is the "looks almost right" failure, and no golden compares
    /// pixels to catch it.
    #[test]
    fn a_partial_arc_paints_nothing_rather_than_a_full_ellipse() {
        let half = EllipseArc {
            cx: 8.0, cy: 8.0, rx: 6.0, ry: 6.0, rotation: 0.0,
            start: 0.0, end: std::f64::consts::PI, ccw: false,
        };
        let buf = draw(16, 16, |p| p.fill_ellipse_arc(&half, FillRule::NonZero, &red(), 1.0));
        assert!(buf.chunks(4).all(|q| q == [0, 0, 0, 0]),
                "a partial arc must not become a disc");
    }

    /// The corpus rounds to 4 decimals, so a full sweep arrives as 6.2832 --
    /// 1.5e-5 short of TAU. A tolerance tuned to f64 would classify every
    /// recorded circle as partial and draw nothing at all. This pins the
    /// tolerance to the corpus's own precision.
    #[test]
    fn a_corpus_rounded_full_sweep_still_counts_as_full() {
        let rounded = EllipseArc {
            cx: 8.0, cy: 8.0, rx: 6.0, ry: 6.0, rotation: 0.0,
            start: 0.0, end: 6.2832, ccw: false,
        };
        let buf = draw(16, 16, |p| p.fill_ellipse_arc(&rounded, FillRule::NonZero, &red(), 1.0));
        assert_eq!(px(&buf, 16, 8, 8), [0, 0, 255, 255],
                   "6.2832 is how the corpus spells a full circle");
    }

    /// clip restricts a later fill, and pop_state undoes it.
    #[test]
    fn clip_restricts_the_fill_and_pop_state_releases_it() {
        let ident = Transform { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 0.0, f: 0.0 };
        let buf = draw(16, 16, |p| {
            p.push_state(ident);
            p.clip(&[
                PathCommand::MoveTo { x: 0.0, y: 0.0 },
                PathCommand::LineTo { x: 8.0, y: 0.0 },
                PathCommand::LineTo { x: 8.0, y: 8.0 },
                PathCommand::LineTo { x: 0.0, y: 8.0 },
                PathCommand::ClosePath,
            ], FillRule::NonZero);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 16.0, h: 16.0 }, &red(), 1.0);
            p.pop_state();
        });
        assert_eq!(px(&buf, 16, 4, 4), [0, 0, 255, 255], "inside the clip");
        assert_eq!(px(&buf, 16, 12, 12), [0, 0, 0, 0], "outside the clip is untouched");
    }

    /// `clip` takes a `FillRule` and until now NOTHING exercised it — the one
    /// clip test uses a single square, where NonZero and EvenOdd agree. A
    /// backend that ignored the argument and always used NonZero would have
    /// passed it forever, and the first report would be a clipped group with a
    /// hole in it rendering solid.
    ///
    /// The discriminating shape is a donut whose two rings wind the SAME way:
    /// EvenOdd makes the inner square a hole, NonZero fills it. Both windings
    /// are asserted, so the test states that the argument CHANGES the answer
    /// rather than merely that one value works.
    #[test]
    fn clip_honours_the_winding_rule_it_is_given() {
        let ident = Transform { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e: 0.0, f: 0.0 };
        // Outer ring (2,2)-(14,14) and inner ring (6,6)-(10,10), same direction.
        let donut = [
            PathCommand::MoveTo { x: 2.0, y: 2.0 },
            PathCommand::LineTo { x: 14.0, y: 2.0 },
            PathCommand::LineTo { x: 14.0, y: 14.0 },
            PathCommand::LineTo { x: 2.0, y: 14.0 },
            PathCommand::ClosePath,
            PathCommand::MoveTo { x: 6.0, y: 6.0 },
            PathCommand::LineTo { x: 10.0, y: 6.0 },
            PathCommand::LineTo { x: 10.0, y: 10.0 },
            PathCommand::LineTo { x: 6.0, y: 10.0 },
            PathCommand::ClosePath,
        ];
        let under = |rule: FillRule| {
            draw(16, 16, |p| {
                p.push_state(ident);
                p.clip(&donut, rule);
                p.fill_rect(Rect { x: 0.0, y: 0.0, w: 16.0, h: 16.0 }, &red(), 1.0);
                p.pop_state();
            })
        };

        let eo = under(FillRule::EvenOdd);
        assert_eq!(px(&eo, 16, 4, 8), [0, 0, 255, 255], "EvenOdd: the ring paints");
        assert_eq!(px(&eo, 16, 8, 8), [0, 0, 0, 0],
                   "EvenOdd: the inner square must be a HOLE");

        let nz = under(FillRule::NonZero);
        assert_eq!(px(&nz, 16, 4, 8), [0, 0, 255, 255], "NonZero: the ring paints");
        assert_eq!(px(&nz, 16, 8, 8), [0, 0, 255, 255],
                   "NonZero: same-wound inner square is FILLED -- if this matches \
                    the EvenOdd result, clip is ignoring the winding argument");
    }

    /// `stroke_rect` had NO test at all. It is one of the two contract methods
    /// the shared proof scene never exercises, so no painter had been checked
    /// on it in any port.
    ///
    /// The load-bearing property is the one that separates it from `fill_rect`:
    /// it draws a BORDER and leaves the interior alone. A backend that
    /// implemented it as a fill would look right on a small dark shape and
    /// wrong on everything else.
    #[test]
    fn stroke_rect_draws_a_border_and_leaves_the_interior_empty() {
        let s = StrokeStyle {
            width: 2.0, cap: LineCap::Butt, join: LineJoin::Miter,
            miter: 10.0, dash: vec![],
        };
        let buf = draw(16, 16, |p| {
            p.stroke_rect(Rect { x: 4.0, y: 4.0, w: 8.0, h: 8.0 }, &red(), &s, 1.0);
        });
        assert_eq!(px(&buf, 16, 4, 8), [0, 0, 255, 255], "the left edge is painted");
        assert_eq!(px(&buf, 16, 8, 8), [0, 0, 0, 0],
                   "the INTERIOR must be untouched -- this is what separates \
                    stroke_rect from fill_rect");
    }

    /// The stroke STRADDLES the edge rather than sitting inside it: a width-2
    /// stroke on an edge at x=4 covers x in [3,5]. Pinned because the three
    /// plausible conventions (centred / inside / outside) differ by exactly
    /// half a stroke width, and Canvas2D's `strokeRect` centres — so a D2D
    /// backend that inset its rectangle would be a silent half-width
    /// divergence, the same shape as the aligned-stroke dash-divisor trap B1
    /// carried into this build.
    #[test]
    fn stroke_rect_straddles_the_edge_it_is_given() {
        let s = StrokeStyle {
            width: 2.0, cap: LineCap::Butt, join: LineJoin::Miter,
            miter: 10.0, dash: vec![],
        };
        let buf = draw(16, 16, |p| {
            p.stroke_rect(Rect { x: 4.0, y: 4.0, w: 8.0, h: 8.0 }, &red(), &s, 1.0);
        });
        assert_eq!(px(&buf, 16, 3, 8), [0, 0, 255, 255],
                   "OUTSIDE the geometric edge is painted -- the stroke straddles");
        assert_eq!(px(&buf, 16, 6, 8), [0, 0, 0, 0],
                   "two units inside the edge is clear -- the stroke is not inset");
    }

    /// A dashed `stroke_rect` must actually leave gaps. This is the only test
    /// that drives `dash_multiples` through `stroke_rect`, and the dash-unit
    /// conversion is the trap B1 named: D2D dash entries are MULTIPLES OF THE
    /// STROKE WIDTH while the contract carries user units, so a missing divide
    /// draws one dash the length of the whole side and reads as a solid border.
    ///
    /// Counted rather than pixel-probed, so it does not encode a phase: a
    /// dashed border must paint strictly fewer pixels than a solid one and
    /// strictly more than none.
    #[test]
    fn a_dashed_stroke_rect_leaves_gaps() {
        let base = StrokeStyle {
            width: 2.0, cap: LineCap::Butt, join: LineJoin::Miter,
            miter: 10.0, dash: vec![],
        };
        let dashed = StrokeStyle { dash: vec![2.0, 2.0], ..base.clone() };
        let painted = |s: &StrokeStyle| {
            let buf = draw(16, 16, |p| {
                p.stroke_rect(Rect { x: 4.0, y: 4.0, w: 8.0, h: 8.0 }, &red(), s, 1.0);
            });
            (0..16).flat_map(|y| (0..16).map(move |x| (x, y)))
                .filter(|(x, y)| px(&buf, 16, *x, *y)[3] != 0)
                .count()
        };
        let solid_px = painted(&base);
        let dashed_px = painted(&dashed);
        assert!(solid_px > 0, "the solid border painted nothing; the probe is broken");
        assert!(dashed_px > 0,
                "the dashed border painted NOTHING -- a dash pattern that erases \
                 the stroke means the unit conversion overshot");
        assert!(dashed_px < solid_px,
                "the dashed border painted {dashed_px} pixels and the solid one \
                 {solid_px}: no gaps, so the dash array reached D2D without being \
                 divided by the emit width");
    }

    /// Masks must REFUSE, not draw something plausible. A backend that quietly
    /// ignored a mask would render the unmasked artwork and look almost right.
    ///
    /// ⛔ AND THIS TEST NOW PINS THE LEDGER NAME (A6 item ④). It used to expect
    /// "element-bracket ruling"; the site cited "option C, 2026-07-30" while the
    /// summons cited "option (a)" — one object under two labels. The reconciled
    /// name is A6, and this expectation is what keeps a third label from
    /// appearing here: change the refusal's name and this test reds.
    ///
    /// Renamed with the message: the bracket is no longer "pending" — it is
    /// ratified (2026-08-27). What is pending is this backend's IMPLEMENTATION.
    #[test]
    #[should_panic(expected = "pending the A6 implementation")]
    fn masks_refuse_loudly_pending_the_a6_implementation() {
        let t = HeadlessTarget::new(2, 2).unwrap();
        let mut p = Direct2DPainter::new(t.target());
        p.push_mask_layer(Mask::AlphaClipOut);
    }
}
