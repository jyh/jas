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

use windows::core::{Interface, Result};
use windows::Win32::Graphics::Direct2D::{
    ID2D1Bitmap, ID2D1BitmapRenderTarget, ID2D1DeviceContext, CLSID_D2D1Blend,
    CLSID_D2D1LuminanceToAlpha, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,
    D2D1_BLEND_PROP_MODE, D2D1_INTERPOLATION_MODE_LINEAR, D2D1_PROPERTY_TYPE_ENUM,
};
use windows::Win32::Graphics::Direct2D::Common::{
    D2D1_BLEND_MODE, D2D1_BLEND_MODE_COLOR, D2D1_BLEND_MODE_COLOR_BURN,
    D2D1_BLEND_MODE_COLOR_DODGE, D2D1_BLEND_MODE_DARKEN, D2D1_BLEND_MODE_DIFFERENCE,
    D2D1_BLEND_MODE_EXCLUSION, D2D1_BLEND_MODE_HARD_LIGHT, D2D1_BLEND_MODE_HUE,
    D2D1_BLEND_MODE_LIGHTEN, D2D1_BLEND_MODE_LUMINOSITY, D2D1_BLEND_MODE_MULTIPLY,
    D2D1_BLEND_MODE_OVERLAY, D2D1_BLEND_MODE_SATURATION, D2D1_BLEND_MODE_SCREEN,
    D2D1_BLEND_MODE_SOFT_LIGHT,
};
use windows::Win32::Graphics::Direct2D::Common::{
    D2D1_COMPOSITE_MODE_DESTINATION_OUT, D2D1_COMPOSITE_MODE_SOURCE_IN,
    D2D1_COMPOSITE_MODE_SOURCE_OVER,
};
use windows::Win32::Graphics::Direct2D::Common::{
    D2D1_COLOR_F, D2D1_GRADIENT_STOP, D2D_RECT_F,
};
use windows::Win32::Graphics::Direct2D::{
    ID2D1Brush, ID2D1RenderTarget, ID2D1SolidColorBrush, ID2D1StrokeStyle,
    D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, D2D1_ELLIPSE, D2D1_EXTEND_MODE_CLAMP,
    ID2D1Geometry,
    D2D1_GAMMA_2_2, D2D1_LAYER_OPTIONS_NONE, D2D1_LAYER_PARAMETERS,
    D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES, D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES,
};
use windows_numerics::Matrix3x2;

use super::{convert, geometry, text};
use crate::geometry::element::Color;
use crate::painter::{StrokeAlign, 
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

/// One open isolated layer (A6): its own surface in the parent's frame, plus
/// the alpha and blend consumed once at the closing composite.
struct LayerTarget {
    /// Kept because `GetBitmap` is how the composite reads the layer back.
    brt: ID2D1BitmapRenderTarget,
    /// The same object as `brt`, pre-cast, so the hot accessor never casts.
    rt: ID2D1RenderTarget,
    alpha: f64,
    #[allow(dead_code)] // consumed at the composite once non-Normal blends land
    blend: BlendMode,
    /// A6 §3.2: the open-group product RESTARTS at 1.0 inside the layer, so the
    /// parent's is set aside here and restored by the pop.
    saved_group_alphas: Vec<f64>,
    /// The mask this layer's body must be eaten into at composite time, if any.
    ///
    /// ⭐ THE LAW IS APPLIED AT THE BLIT, NOT AT `pop_mask_layer`, and that is
    /// the design rather than a convenience. A6 puts the isolated layer there
    /// precisely so the law has a finished body buffer to eat into; applying it
    /// earlier would mean masking a surface that is still open for drawing, and
    /// D2D has no way to re-run a composite over a target mid-`BeginDraw`.
    mask: Option<(ID2D1Bitmap, Mask)>,
}

/// One open mask bracket: its own surface, and the law to apply on close.
struct MaskTarget {
    brt: ID2D1BitmapRenderTarget,
    rt: ID2D1RenderTarget,
    law: Mask,
}

pub struct Direct2DPainter<'a> {
    base_rt: &'a ID2D1RenderTarget,
    frames: Vec<Frame>,
    /// The owned multiply stack. See the module note: NOT a layer.
    group_alphas: Vec<f64>,
    /// The BLEND of each open `push_group`, parallel to `group_alphas`.
    ///
    /// ⭐ ROW CM's last golden. A group is NON-ISOLATED by contract: its blend
    /// applies to every descendant primitive against the LIVE backdrop, one
    /// primitive at a time. That is a different job from the isolated layer's
    /// single closing composite, and it is why this is a stack of MODES rather
    /// than a surface.
    ///
    /// ⛔ THE INNERMOST WINS, not a product. The seam's own contract: "a nested
    /// `push_group` resets it and leaf primitives inherit the innermost group's
    /// blend -- matching today, where a Group's own mode is overridden by its
    /// children." Compounding them would invent a behaviour no port has.
    group_blends: Vec<BlendMode>,
    /// Open isolated layers, innermost last. Empty is the common case and
    /// costs one `is_empty` per draw.
    layers: Vec<LayerTarget>,
    /// Open mask brackets. While one is open every draw is MASK CONTENT and
    /// goes to the mask surface, never to the body.
    masks: Vec<MaskTarget>,
    /// ⛔ A FAILED OPEN MUST NOT SILENTLY DRAW ON THE PARENT. If the layer
    /// surface cannot be made, the body would composite against the very
    /// backdrop it was supposed to be isolated from -- visibly wrong, and
    /// invisible to a display-list golden. Counting the failure keeps the
    /// matching pop balanced and composites nothing. Same law as canvas2d.
    failed_layers: usize,
    /// ⛔ A TEXT RUN THIS BACKEND COULD NOT DRAW, HELD FOR THE CALLER TO COLLECT.
    ///
    /// `Painter::draw_text_run` returns `()` and the trait is FROZEN, so a
    /// failure inside it has no return path — which is exactly how
    /// `draw_fast_run`'s `bool` came to be discarded and an unresolvable font
    /// came to draw nothing while reporting nothing. This field is the return
    /// path the signature cannot have: the painter records, and `replay` drains
    /// it into the report through [`take_text_refusal`](Self::take_text_refusal).
    ///
    /// Same shape as `failed_layers` above and for the same reason — a failure
    /// the display list cannot express must still be counted somewhere.
    text_refusal: Option<&'static str>,
}

impl<'a> Direct2DPainter<'a> {
    pub fn new(rt: &'a ID2D1RenderTarget) -> Self {
        Self {
            base_rt: rt,
            frames: Vec::new(),
            group_alphas: Vec::new(),
            group_blends: Vec::new(),
            layers: Vec::new(),
            masks: Vec::new(),
            failed_layers: 0,
            text_refusal: None,
        }
    }

    /// Take the last text refusal, if the previous `draw_text_run` could not
    /// draw. Clears it, so one refusal is reported once.
    ///
    /// ⚠️ NOT ON THE `Painter` TRAIT, deliberately. The trait is frozen and a
    /// backend-specific collection point is not contract vocabulary; `replay`
    /// holds a concrete `&mut Direct2DPainter` and can simply ask.
    pub fn take_text_refusal(&mut self) -> Option<&'static str> {
        self.text_refusal.take()
    }

    /// Re-composite `body` through `mask` under `law`, onto a fresh surface.
    ///
    /// THE THREE A6 LAWS, LOWERED ONTO D2D COMPOSITE MODES:
    ///
    /// | law | graph |
    /// |---|---|
    /// | `LuminanceClipIn` | mask -> LuminanceToAlpha, then body SOURCE_IN |
    /// | `AlphaClipOut` | body, then mask DESTINATION_OUT |
    /// | `AlphaRevealOutsideBbox` | body, then mask DESTINATION_OUT **clipped to the bbox** |
    ///
    /// ⭐ The third is the second with a clip, and that is the enum's own
    /// collapse showing through: outside the bbox nothing is cut, so the body is
    /// revealed there. Writing it as a third graph would have hidden that they
    /// share a law.
    ///
    /// ⚠️ LUMINANCE IS THE EFFECT'S, NOT MINE. `CLSID_D2D1LuminanceToAlpha` uses
    /// its own coefficients; the seam doc names BT.601 (browser) against BT.709
    /// (vello) as the R8 ratification point. This backend therefore agrees with
    /// whichever D2D uses, and that choice is RECORDED rather than reconciled:
    /// if R8 later rules a coefficient set, this is the site that changes.
    ///
    /// ⚠️ No cross-backend comparison is claimed or implied. Establishing one
    /// would be its own row with its own harness, priced first (helm, 08/29).
    fn apply_mask(&self, body: &ID2D1Bitmap, mask: &ID2D1Bitmap, law: Mask) -> Option<ID2D1Bitmap> {
        let (brt, rt) = self.open_surface()?;
        // The composite runs in DEVICE space: both bitmaps are already in the
        // parent's frame, so a transform here would apply it twice.
        unsafe { rt.SetTransform(&Matrix3x2::identity()) };
        let dc: ID2D1DeviceContext = rt.cast().ok()?;

        let ok = (|| -> Option<()> {
            match law {
                Mask::LuminanceClipIn => {
                    let eff = unsafe { dc.CreateEffect(&CLSID_D2D1LuminanceToAlpha) }.ok()?;
                    unsafe { eff.SetInput(0, mask, true) };
                    let out = unsafe { eff.GetOutput() }.ok()?;
                    unsafe {
                        dc.DrawImage(&out, None, None,
                            D2D1_INTERPOLATION_MODE_LINEAR,
                            D2D1_COMPOSITE_MODE_SOURCE_OVER);
                        dc.DrawImage(body, None, None,
                            D2D1_INTERPOLATION_MODE_LINEAR,
                            D2D1_COMPOSITE_MODE_SOURCE_IN);
                    }
                }
                Mask::AlphaClipOut => unsafe {
                    dc.DrawImage(body, None, None,
                        D2D1_INTERPOLATION_MODE_LINEAR,
                        D2D1_COMPOSITE_MODE_SOURCE_OVER);
                    dc.DrawImage(mask, None, None,
                        D2D1_INTERPOLATION_MODE_LINEAR,
                        D2D1_COMPOSITE_MODE_DESTINATION_OUT);
                },
                Mask::AlphaRevealOutsideBbox { bbox } => unsafe {
                    dc.DrawImage(body, None, None,
                        D2D1_INTERPOLATION_MODE_LINEAR,
                        D2D1_COMPOSITE_MODE_SOURCE_OVER);
                    let r = D2D_RECT_F {
                        left: bbox.x as f32,
                        top: bbox.y as f32,
                        right: (bbox.x + bbox.w) as f32,
                        bottom: (bbox.y + bbox.h) as f32,
                    };
                    dc.PushAxisAlignedClip(&r, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
                    dc.DrawImage(mask, None, None,
                        D2D1_INTERPOLATION_MODE_LINEAR,
                        D2D1_COMPOSITE_MODE_DESTINATION_OUT);
                    dc.PopAxisAlignedClip();
                },
            }
            Some(())
        })();

        unsafe { let _ = rt.EndDraw(None, None); }
        ok?;
        unsafe { brt.GetBitmap() }.ok()
    }

    /// The D2D effect mode for one of the fifteen non-Normal blends.
    ///
    /// ⛔ `Normal` IS DELIBERATELY ABSENT — it returns `None`, and the caller
    /// takes the plain `DrawBitmap` path. There is no D2D "normal" blend mode
    /// (source-over is not in that enum), so a mapping that invented one would
    /// have to pick a wrong answer and hide it behind a total function.
    ///
    /// jas's sixteen are a SUBSET of D2D's twenty-six; every line below is the
    /// same law under the same name in the W3C compositing spec, which is what
    /// both vocabularies are derived from.
    fn d2d_blend_mode(blend: BlendMode) -> Option<D2D1_BLEND_MODE> {
        Some(match blend {
            BlendMode::Normal => return None,
            BlendMode::Multiply => D2D1_BLEND_MODE_MULTIPLY,
            BlendMode::Screen => D2D1_BLEND_MODE_SCREEN,
            BlendMode::Darken => D2D1_BLEND_MODE_DARKEN,
            BlendMode::Lighten => D2D1_BLEND_MODE_LIGHTEN,
            BlendMode::ColorBurn => D2D1_BLEND_MODE_COLOR_BURN,
            BlendMode::ColorDodge => D2D1_BLEND_MODE_COLOR_DODGE,
            BlendMode::Overlay => D2D1_BLEND_MODE_OVERLAY,
            BlendMode::SoftLight => D2D1_BLEND_MODE_SOFT_LIGHT,
            BlendMode::HardLight => D2D1_BLEND_MODE_HARD_LIGHT,
            BlendMode::Difference => D2D1_BLEND_MODE_DIFFERENCE,
            BlendMode::Exclusion => D2D1_BLEND_MODE_EXCLUSION,
            BlendMode::Hue => D2D1_BLEND_MODE_HUE,
            BlendMode::Saturation => D2D1_BLEND_MODE_SATURATION,
            BlendMode::Color => D2D1_BLEND_MODE_COLOR,
            BlendMode::Luminosity => D2D1_BLEND_MODE_LUMINOSITY,
        })
    }

    /// A snapshot of `parent`'s current pixels — the BACKDROP a blend needs.
    ///
    /// ⛔ A BLEND IS A FUNCTION OF TWO IMAGES AND ONE OF THEM IS ALREADY ON THE
    /// TARGET. That is the whole reason non-Normal blend stayed unbuilt here:
    /// every other composite in this backend is a one-way write, and this is the
    /// only one that has to READ what is underneath. `CopyFromRenderTarget` is
    /// that read; it copies DEVICE pixels, so like the closing blit it is only
    /// correct at identity.
    fn snapshot(&self, parent: &ID2D1RenderTarget) -> Option<ID2D1Bitmap> {
        let dc: ID2D1DeviceContext = parent.cast().ok()?;
        let brt = unsafe {
            dc.CreateCompatibleRenderTarget(None, None, None, Default::default())
        }.ok()?;
        let bmp = unsafe { brt.GetBitmap() }.ok()?;
        unsafe { bmp.CopyFromRenderTarget(None, parent, None) }.ok()?;
        Some(bmp)
    }

    /// Composite `body` onto `parent` under a non-Normal `blend`, at `eff`.
    ///
    /// ⚖️ THE ALPHA MODULATES THE RESULT, NOT THE SOURCE, and getting that
    /// backwards is the one arithmetic trap here. W3C compositing gives
    /// `Cr = (1 - as)·Cb + as·Blend(Cb, Cs)` — the layer alpha weights the
    /// BLENDED colour against the backdrop. Pre-multiplying it into `Cs` and
    /// then blending gives `Blend(Cb, as·Cs)`, which for a 0.5-alpha multiply
    /// over 0.8 yields 0.20 where the right answer is 0.60: a plausible picture
    /// and the wrong one.
    ///
    /// So: blend at FULL strength into a scratch surface, then source-over that
    /// result at `eff`. Because the parent still holds `Cb`, that composite IS
    /// the formula above — no separate lerp is needed and none is written.
    ///
    /// Returns `false` on any failure so the caller can fall back rather than
    /// drop the layer entirely.
    fn composite_blended(
        &self,
        parent: &ID2D1RenderTarget,
        body: &ID2D1Bitmap,
        eff: f32,
        blend: BlendMode,
    ) -> bool {
        let Some(mode) = Self::d2d_blend_mode(blend) else { return false };
        let Some(backdrop) = self.snapshot(parent) else { return false };
        let Ok(dc) = parent.cast::<ID2D1DeviceContext>() else { return false };
        let Ok(brt) = (unsafe {
            dc.CreateCompatibleRenderTarget(None, None, None, Default::default())
        }) else { return false };
        let Ok(rt) = brt.cast::<ID2D1RenderTarget>() else { return false };
        let Ok(scratch) = rt.cast::<ID2D1DeviceContext>() else { return false };

        let ok = (|| -> Option<()> {
            unsafe {
                rt.BeginDraw();
                // Identity: both inputs are already device-space bitmaps.
                rt.SetTransform(&Matrix3x2::identity());
                rt.Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 0.0 }));
            }
            let fx = unsafe { scratch.CreateEffect(&CLSID_D2D1Blend) }.ok()?;
            unsafe {
                // ⛔ INPUT 0 IS THE DESTINATION (the backdrop), INPUT 1 THE
                // SOURCE. Swapping them is invisible for Multiply and Screen —
                // both commutative — and WRONG for ColorBurn, Overlay,
                // HardLight and the rest of the separable set. A Multiply-only
                // corpus structurally cannot catch it, which is why the order is
                // stated here rather than left to the reader.
                fx.SetInput(0, &backdrop, true);
                fx.SetInput(1, body, true);
                fx.SetValue(
                    D2D1_BLEND_PROP_MODE.0 as u32,
                    D2D1_PROPERTY_TYPE_ENUM,
                    &mode.0.to_le_bytes(),
                ).ok()?;
                let out = fx.GetOutput().ok()?;
                scratch.DrawImage(
                    &out, None, None,
                    D2D1_INTERPOLATION_MODE_LINEAR,
                    D2D1_COMPOSITE_MODE_SOURCE_OVER,
                );
            }
            Some(())
        })();
        unsafe { let _ = rt.EndDraw(None, None); }
        if ok.is_none() { return false; }

        let Ok(blended) = (unsafe { brt.GetBitmap() }) else { return false };
        unsafe {
            parent.DrawBitmap(
                &blended, None, eff,
                D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,
                None,
            );
        }
        true
    }

    /// The innermost open group's blend, when it is not Normal.
    ///
    /// ⚠️ NOT A PRODUCT OVER THE STACK. See `group_blends`: the contract says
    /// the innermost wins and a nested group RESETS it.
    fn active_group_blend(&self) -> Option<BlendMode> {
        match self.group_blends.last() {
            Some(b) if *b != BlendMode::Normal => Some(*b),
            _ => None,
        }
    }

    /// Draw one primitive, blending it against the LIVE backdrop when a
    /// non-Normal group is open.
    ///
    /// ⭐ ROW CM's last golden, and the shape of the job is the whole point.
    /// `pop_isolated_layer` blends ONCE, at the close, because a layer is
    /// isolated: its contents are flattened first and meet the backdrop as one
    /// image. A GROUP is non-isolated, so each primitive must meet the backdrop
    /// on its own -- **including the backdrop its siblings just changed**. That
    /// is what makes two overlapping half-multiplies compound to 0.20 rather
    /// than flatten to 0.40, and it is asserted by
    /// `overlapping_primitives_in_a_blended_group_compound_rather_than_isolate`.
    ///
    /// ⇒ So this is a surface + composite PER PRIMITIVE. It is the expensive
    /// shape, and it is the correct one; a spike backend buys correctness here
    /// and prices speed later.
    ///
    /// ⛔ THE BRUSH IS BUILT INSIDE THE CLOSURE, on the scratch target, never
    /// hoisted. A D2D brush belongs to the render target that created it, so a
    /// brush made on the parent and used on the scratch is a resource crossing a
    /// boundary it does not cross -- the same class as the
    /// `GetIUnknownForObject` heap corruption this lane already found once.
    fn blended_primitive(&mut self, f: impl FnOnce(&ID2D1RenderTarget)) {
        let Some(blend) = self.active_group_blend() else {
            f(&self.rt());
            return;
        };
        let parent = self.rt();
        let Some((brt, rt)) = self.open_surface() else {
            // A scratch we cannot make must not silently drop the primitive:
            // drawing it unblended is a wrong colour, drawing nothing is a
            // missing shape, and the second is the worse failure here.
            f(&parent);
            return;
        };
        f(&rt);
        unsafe { let _ = rt.EndDraw(None, None); }
        let Ok(bmp) = (unsafe { brt.GetBitmap() }) else { return };

        // The composite runs at identity: the primitive was already drawn under
        // the parent's transform, so applying it again would double it.
        let mut saved = Matrix3x2::identity();
        unsafe { parent.GetTransform(&mut saved) };
        unsafe { parent.SetTransform(&Matrix3x2::identity()) };
        if !self.composite_blended(&parent, &bmp, 1.0, blend) {
            unsafe {
                parent.DrawBitmap(&bmp, None, 1.0, D2D1_BITMAP_INTERPOLATION_MODE_LINEAR, None);
            }
        }
        unsafe { parent.SetTransform(&saved) };
    }

    /// THE TARGET EVERY DRAW GOES TO: the innermost open isolated layer, or the
    /// base render target when none is open.
    ///
    /// Returns an OWNED clone rather than a borrow, deliberately. A borrow tied
    /// to `&self` cannot coexist with the `&mut self` the draw methods hold, and
    /// the workarounds are worse than one AddRef: a COM clone is a refcount
    /// bump, and it keeps every call site reading as it did before.
    fn rt(&self) -> ID2D1RenderTarget {
        // ORDER MATTERS: a mask bracket is INSIDE whatever layer is open, so an
        // open mask wins. Getting this backwards would draw the mask content
        // into the body it is supposed to be masking -- and the body would look
        // plausible, which is the worst way to be wrong.
        if let Some(m) = self.masks.last() {
            return m.rt.clone();
        }
        match self.layers.last() {
            Some(l) => l.rt.clone(),
            None => self.base_rt.clone(),
        }
    }

    /// Make a fresh transparent surface in the CURRENT target's frame.
    /// Shared by the isolated-layer and mask-bracket opens: both need exactly
    /// this, and two copies would drift.
    fn open_surface(&self) -> Option<(ID2D1BitmapRenderTarget, ID2D1RenderTarget)> {
        let parent = self.rt();
        let dc: ID2D1DeviceContext = parent.cast().ok()?;
        let brt = unsafe {
            dc.CreateCompatibleRenderTarget(None, None, None, Default::default())
        }.ok()?;
        let rt: ID2D1RenderTarget = brt.cast().ok()?;
        let mut t = Matrix3x2::identity();
        unsafe { parent.GetTransform(&mut t) };
        unsafe { rt.SetTransform(&t) };
        unsafe { rt.BeginDraw() };
        unsafe { rt.Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 0.0 })) };
        Some((brt, rt))
    }

    /// `product(open group alphas) * paint_alpha`, clamped. This is the whole
    /// of group alpha and it is why no offscreen is needed.
    pub fn effective_alpha(&self, paint_alpha: f64) -> f64 {
        let p: f64 = self.group_alphas.iter().product::<f64>() * paint_alpha;
        p.clamp(0.0, 1.0)
    }

    fn solid(&self, c: Color, alpha: f64) -> Result<ID2D1SolidColorBrush> {
        Self::solid_on(&self.rt(), c, alpha)
    }

    /// `solid`, on a NAMED target — see `brush_on` for why that matters.
    fn solid_on(rt: &ID2D1RenderTarget, c: Color, alpha: f64) -> Result<ID2D1SolidColorBrush> {
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
        unsafe { rt.CreateSolidColorBrush(&col, None) }
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
        Self::stops_on(&self.rt(), stops, alpha)
    }

    /// `stops`, on a NAMED target — see `brush_on`.
    fn stops_on(rt: &ID2D1RenderTarget, stops: &[crate::painter::ColorStop], alpha: f64)
        -> Option<windows::Win32::Graphics::Direct2D::ID2D1GradientStopCollection>
    {
        let v: Vec<D2D1_GRADIENT_STOP> = stops.iter().map(|s| {
            let (r, g, b, a) = s.color.to_rgba();
            D2D1_GRADIENT_STOP {
                position: s.offset as f32,
                color: D2D1_COLOR_F { r: r as f32, g: g as f32, b: b as f32, a: (a * alpha) as f32 },
            }
        }).collect();
        unsafe { rt.CreateGradientStopCollection(&v, D2D1_GAMMA_2_2, D2D1_EXTEND_MODE_CLAMP) }.ok()
    }

    fn brush(&self, b: &Brush, alpha: f64) -> Option<ID2D1Brush> {
        Self::brush_on(&self.rt(), b, alpha)
    }

    /// `brush`, on a NAMED target.
    ///
    /// ⛔ A D2D BRUSH BELONGS TO THE RENDER TARGET THAT CREATED IT. The
    /// per-primitive group-blend path draws onto a scratch surface, so its
    /// brushes must be created there -- a brush made on the parent and used on
    /// the scratch is a resource crossing a boundary it does not cross.
    fn brush_on(rt: &ID2D1RenderTarget, b: &Brush, alpha: f64) -> Option<ID2D1Brush> {
        match b {
            Brush::Solid(c) => Self::solid_on(rt, *c, alpha).ok().map(|s| s.into()),
            Brush::Linear(g) => {
                let sc = Self::stops_on(rt, &g.stops, alpha)?;
                let props = D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES {
                    startPoint: windows_numerics::Vector2 { X: g.x0 as f32, Y: g.y0 as f32 },
                    endPoint: windows_numerics::Vector2 { X: g.x1 as f32, Y: g.y1 as f32 },
                };
                unsafe { rt.CreateLinearGradientBrush(&props, None, &sc) }.ok().map(|b| b.into())
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
                let sc = Self::stops_on(rt, &g.stops, alpha)?;
                let props = D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES {
                    center: windows_numerics::Vector2 { X: g.x1 as f32, Y: g.y1 as f32 },
                    gradientOriginOffset: windows_numerics::Vector2 {
                        X: (g.x0 - g.x1) as f32, Y: (g.y0 - g.y1) as f32,
                    },
                    radiusX: g.r1 as f32,
                    radiusY: g.r1 as f32,
                };
                unsafe { rt.CreateRadialGradientBrush(&props, None, &sc) }.ok().map(|b| b.into())
            }
        }
    }

    fn stroke_style(&self, s: &StrokeStyle, emit_width: f64) -> Option<ID2D1StrokeStyle> {
        Self::stroke_style_on(&self.rt(), s, emit_width)
    }

    /// `stroke_style`, on a NAMED target. A stroke style is a FACTORY resource
    /// and the scratch shares the parent's factory, so this is uniformity with
    /// `brush_on` rather than a correctness requirement — but a reader should
    /// not have to work out which of the two it is at every call site.
    fn stroke_style_on(rt: &ID2D1RenderTarget, s: &StrokeStyle, emit_width: f64) -> Option<ID2D1StrokeStyle> {
        let props = convert::stroke_properties(s);
        let dashes = convert::dash_multiples(&s.dash, emit_width);
        let factory = unsafe { rt.GetFactory() }.ok()?;
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
    /// ⚖️ THE FLIP (council 08/29, row e closes with it). AMENDMENT A6 §6.2 —
    /// A RATIFIED BEHAVIOUR CHANGE, AND IT IS ANNOUNCED, NOT QUIET.
    ///
    /// This backend answered NO to everything because its A6 bodies were four
    /// `unimplemented!()`. They are implemented now (row e(a)), so the answer
    /// changes — **the ROUTER does not**. That was the whole point of putting
    /// the query at the trait: a backend gaining a capability edits one method.
    ///
    /// | capability | answer | why, in this backend's own terms |
    /// |---|---|---|
    /// | `IsolatedLayers` | **yes** | `push_isolated_layer` opens a real surface (a render-target swap, B1's finding: `D2D1_LAYER_PARAMETERS1` serves none of the three mask laws) and `pop_isolated_layer` composites it once at `(group product at the push site) × alpha` |
    /// | `MaskLayers` | **yes** | the mask bracket renders to its own surface and hands its law to the enclosing layer |
    /// | `NonNormalBlend` (the ISOLATED-LAYER bracket) | **yes, since 2026-09-01** | `pop_isolated_layer` snapshots the backdrop (`CopyFromRenderTarget`) and composites through a `CLSID_D2D1Blend` graph, ONCE, exactly as the contract says `alpha` and `blend` are consumed. See `composite_blended`. |
    /// | `NonNormalGroupBlend` (a NON-ISOLATED group) | **yes, since 2026-09-02** | `blended_primitive` draws each descendant onto a scratch and composites it through the same blend graph against the LIVE backdrop — per primitive, which is what non-isolated means. |
    ///
    /// ⭐ **EVERY ANSWER IS NOW YES, AND THE SPLIT THAT MADE THAT SAYABLE HAS
    /// SERVED ITS PURPOSE.** `NonNormalBlend` and `NonNormalGroupBlend` were one
    /// capability until 2026-09-01, split when building the layer half falsified
    /// the merge's stated premise ("one capability because it is one missing
    /// thing"). Both halves are built now, so the premise is true again in the
    /// other direction and the two could honestly be re-merged. **They are left
    /// split deliberately**: a backend that implements one and not the other is
    /// a state the fleet has now been in, and the vocabulary should be able to
    /// say so without a second discovery.
    ///
    /// ⛔ THE THIRD ROW IS NOT A LEFTOVER, IT IS THE CONDITION. The blend gap
    /// must not be folded into the mask/layer answer, and until 08/29 the
    /// vocabulary could not keep them apart: `a6_blend.json` puts a `multiply`
    /// on `push_isolated_layer`, so a single `IsolatedLayers → yes` would have
    /// carried a blend claim this backend cannot honour. `LayerTarget.blend` is
    /// stored and read by nothing — its own `#[allow(dead_code)]` says so.
    ///
    /// 📌 AND TWO INSTRUMENTS DISAGREED ABOUT WHETHER THAT MATTERED, WHICH IS
    /// THE PART WORTH KEEPING. The replay harness ALREADY refuses a blended
    /// layer with the blend reason — this backend's own author separated the two
    /// gaps there and wrote why ("it is a blend gap, not a layer gap, and
    /// collapsing the two would hide which is missing"). So the harness would
    /// have caught a folded answer. The ROUTER would NOT have: it had no blend
    /// clause, so a masked element carrying `multiply` would have been routed
    /// here, the layer would have opened, and the multiply would have gone to a
    /// field nothing reads — silently, in the path that SHIPS. One instrument
    /// saw it and one did not, and the blind one is the one in production.
    ///
    /// ⭐ AND THE THIRD ROW HAS NOW FLIPPED — 2026-09-01. The isolated-layer
    /// blend is built, so `NonNormalBlend` answers **yes** and the router will
    /// route a masked element carrying `multiply` here. `LayerTarget.blend` is
    /// no longer "stored and read by nothing": `pop_isolated_layer` reads it.
    ///
    /// ⛔ THE CAPABILITY HAD TO BE SPLIT FOR THAT ANSWER TO BE HONEST. It
    /// covered *"a blend other than Normal, WHEREVER IT RIDES"* — one name for
    /// `push_group`'s mode and `push_isolated_layer`'s — on the stated ground
    /// that it was *"one missing thing: the effect graph."* Building one half
    /// falsified that: a single answer would have to claim the group blend this
    /// backend still cannot do, or deny the layer blend it now does. The paragraph
    /// above is exactly why the second is not acceptable — a blend reaching a
    /// field nothing reads, silently, in the path that ships.
    ///
    /// ⇒ So `NonNormalGroupBlend` is denied here, the router keeps a
    /// non-Normal-mode GROUP on legacy for this backend, and the replay lane
    /// asserts that these answers and this backend's actual report agree op for
    /// op — which is the arm that caught the flip and forced the split.
    ///
    /// ⚠️ WHAT CHANGES ON SCREEN, said out loud: a masked element under an alpha
    /// ancestor now renders through the A6 bracket here. HEAD's legacy path gave
    /// `own²` with the ancestors DISCARDED; the bracket applies each factor
    /// ONCE. R4 otherwise converts only what preserves behaviour — §6.2 is the
    /// ratified exception.
    ///
    /// 📌 No claim is made or implied about any OTHER backend's output. The
    /// "pixel-equal to Canvas2D" acceptance was withdrawn on 08/29 as
    /// unexecutable, and nothing here rests on it.
    fn supports(&self, cap: crate::painter::capability::Capability) -> bool {
        use crate::painter::capability::Capability as C;
        // Exhaustive on purpose: a new capability must be ANSWERED here, not
        // inherit a default. That is the same reason the trait method has no
        // default body.
        match cap {
            // ⭐ ROW CM's LAST GOLDEN, 2026-09-02: every capability is YES.
            // `NonNormalGroupBlend` was the last NO, and `blended_primitive`
            // answers it — per-primitive compositing against the live backdrop.
            C::IsolatedLayers | C::MaskLayers | C::NonNormalBlend | C::NonNormalGroupBlend => true,
        }
    }

    fn fill_rect(&mut self, rect: Rect, brush: &Brush, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        let br = brush.clone();
        self.blended_primitive(move |rt| {
            if let Some(b) = Self::brush_on(rt, &br, a) {
                unsafe { rt.FillRectangle(&d2d_rect(rect), &b) };
            }
        });
    }

    fn stroke_rect(&mut self, rect: Rect, brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        let (br, st) = (brush.clone(), stroke.clone());
        self.blended_primitive(move |rt| {
            if let Some(b) = Self::brush_on(rt, &br, a) {
                let ss = Self::stroke_style_on(rt, &st, st.width);
                unsafe {
                    rt.DrawRectangle(&d2d_rect(rect), &b, st.width as f32, ss.as_ref())
                };
            }
        });
    }

    fn push_state(&mut self, transform: Transform) {
        let cur = Matrix3x2 {
            M11: transform.a as f32, M12: transform.b as f32,
            M21: transform.c as f32, M22: transform.d as f32,
            M31: transform.e as f32, M32: transform.f as f32,
        };
        let mut prev = Matrix3x2::identity();
        unsafe { self.rt().GetTransform(&mut prev) };
        self.frames.push(Frame { transform: prev, opened: Vec::new() });
        unsafe { self.rt().SetTransform(&(cur * prev)) };
    }

    fn pop_state(&mut self) {
        if let Some(f) = self.frames.pop() {
            // STRICT LIFO. See the Pop note: a mismatch here surfaces as a
            // failed EndDraw far from its cause.
            for p in f.opened.iter().rev() {
                unsafe {
                    match p {
                        Pop::Layer => self.rt().PopLayer(),
                        Pop::AxisAlignedClip => self.rt().PopAxisAlignedClip(),
                    }
                }
            }
            unsafe { self.rt().SetTransform(&f.transform) };
        }
    }

    /// ⭐ ROW CM's LAST GOLDEN. The `debug_assert!` that stood here — *"non-Normal
    /// blend needs a backdrop snapshot + CLSID_D2D1Blend graph (B1); not built"*
    /// — is gone because it is built: `blended_primitive` composites each
    /// descendant primitive against the live backdrop through that graph.
    ///
    /// ⛔ THE BLEND IS PUSHED, NOT VALIDATED. Refusing here was right while
    /// nothing could honour it; keeping the refusal after building the thing it
    /// refused would be a guard nothing drives.
    fn push_group(&mut self, alpha: f64, blend: BlendMode) {
        self.group_alphas.push(alpha);
        self.group_blends.push(blend);
    }

    fn pop_group(&mut self) {
        self.group_alphas.pop();
        self.group_blends.pop();
    }

    fn fill_path(&mut self, path: &[PathCommand], winding: FillRule, brush: &Brush, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        let (br, pth) = (brush.clone(), path.to_vec());
        self.blended_primitive(move |rt| {
            let Some(b) = Self::brush_on(rt, &br, a) else { return };
            let Ok(f) = (unsafe { rt.GetFactory() }) else { return };
            if let Ok(Some(g)) = geometry::build(&f, &pth, winding) {
                unsafe { rt.FillGeometry(&g, &b, None) };
            }
        });
    }

    fn stroke_path(&mut self, path: &[PathCommand], brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        let (br, pth, st) = (brush.clone(), path.to_vec(), stroke.clone());
        self.blended_primitive(move |rt| {
            let Some(b) = Self::brush_on(rt, &br, a) else { return };
            let Ok(f) = (unsafe { rt.GetFactory() }) else { return };
            // A stroked path carries no fill rule; NonZero is the contract
            // default and the rule is irrelevant to stroking.
            if let Ok(Some(g)) = geometry::build(&f, &pth, FillRule::NonZero) {
                let ss = Self::stroke_style_on(rt, &st, st.width);
                unsafe { rt.DrawGeometry(&g, &b, st.width as f32, ss.as_ref()) };
            }
        });
    }

    /// ⭐ ROW EG(1): A PARTIAL ARC IS DRAWN AS THE ARC. This used to `return`
    /// on `full_ellipse`'s `None` — a deliberate refusal at the time, because
    /// silently closing an arc into a disc is the "looks almost right" failure
    /// and no golden compares pixels to catch it. The 2026-09-02 ruling settles
    /// it the other way on every port: draw the arc.
    ///
    /// A FILL closes the arc with a straight line back to its start — a CHORD,
    /// which is what canvas's `ellipse(); fill()` produces. `geometry::arc`
    /// carries that as its `close` flag.
    fn fill_ellipse_arc(&mut self, arc: &EllipseArc, _winding: FillRule, brush: &Brush, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        let (br, ar) = (brush.clone(), arc.clone());
        self.blended_primitive(move |rt| {
            let Some(b) = Self::brush_on(rt, &br, a) else { return };
            if let Some(e) = full_ellipse(&ar) {
                unsafe { rt.FillEllipse(&e, &b) };
                return;
            }
            let Ok(f) = (unsafe { rt.GetFactory() }) else { return };
            // ⚠️ `true` HERE IS INTENT, NOT A SWITCH: `FillGeometry` closes an
            // open figure implicitly, so flipping this flag changes no pixel and
            // a mutant that flips it survives. It is passed truthfully anyway —
            // the geometry a fill wants IS the closed one, and a reader should
            // not have to know D2D's implicit-close rule to see that.
            let Ok(Some(g)) = geometry::arc(&f, &ar, true) else { return };
            unsafe { rt.FillGeometry(&g, &b, None) };
        });
    }

    /// ⭐ THE ALIGNMENT IS DONE HERE, ON THE TRUE CONIC (council 2026-09-02,
    /// EXACT ELLIPSE EVERYWHERE). It used to be lowered by the caller into a
    /// four-cubic bézier ring — contract R4's one named exception, RP3 — because
    /// `Painter::clip` is path-only (amendment A5) and an `EllipseArc` is not a
    /// path. D2D has `CreateEllipseGeometry`, which IS the conic, so the
    /// exception retires rather than being re-bounded.
    ///
    /// The clip and the 2× width are this backend's half of the lowering, done
    /// inside ONE `blended_primitive` closure so the blend machinery sees a
    /// single primitive rather than a half-open layer.
    fn stroke_ellipse_arc(&mut self, arc: &EllipseArc, brush: &Brush, stroke: &StrokeStyle, align: StrokeAlign, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        let (br, ar, st) = (brush.clone(), arc.clone(), stroke.clone());
        self.blended_primitive(move |rt| {
            let Some(b) = Self::brush_on(rt, &br, a) else { return };
            let Some(e) = full_ellipse(&ar) else {
                // ⭐ ROW EG(1): a PARTIAL arc strokes as the arc. `close: false`
                // -- stroking must not draw the chord a fill closes with, or
                // every partial arc grows a bar across its mouth.
                //
                // ⚠️ ALIGNMENT IS NOT HONOURED ON A PARTIAL ARC AND THAT IS
                // STATED, NOT HIDDEN: inside/outside is clip-then-stroke-at-2×,
                // and an OPEN figure has no inside to clip to. No corpus scene
                // strokes a partial arc off-centre today; when one does, this is
                // the line that has to answer for it. Centre is drawn exactly.
                let Ok(f) = (unsafe { rt.GetFactory() }) else { return };
                let Ok(Some(g)) = geometry::arc(&f, &ar, false) else { return };
                let ss = Self::stroke_style_on(rt, &st, st.width);
                unsafe { rt.DrawGeometry(&g, &b, st.width as f32, ss.as_ref()) };
                return;
            };
            if align == StrokeAlign::Center {
                let ss = Self::stroke_style_on(rt, &st, st.width);
                unsafe { rt.DrawEllipse(&e, &b, st.width as f32, ss.as_ref()) };
                return;
            }
            // ⛔ A FAILED CLIP MUST NOT FALL THROUGH TO AN UNCLIPPED STROKE.
            // Drawing the full-width ring where an inside stroke was asked for
            // is a picture that looks almost right, which is the failure this
            // backend refuses everywhere else. Nothing drawn is the honest
            // outcome, and it matches `full_ellipse`'s own None above.
            let Ok(f) = (unsafe { rt.GetFactory() }) else { return };
            let Ok(el) = (unsafe { f.CreateEllipseGeometry(&e) }) else { return };
            let mask: ID2D1Geometry = if align == StrokeAlign::Outside {
                // The outside region is the even-odd complement: a huge rect
                // GROUPED with the ellipse under ALTERNATE fill. Amendment A5's
                // own note describes this compound for the path case; here the
                // ellipse half of it stays an exact conic.
                let big = D2D_RECT_F {
                    left: -1.0e7, top: -1.0e7, right: 1.0e7, bottom: 1.0e7,
                };
                let Ok(rect) = (unsafe { f.CreateRectangleGeometry(&big) }) else { return };
                let parts: [Option<ID2D1Geometry>; 2] =
                    [Some(rect.into()), Some(el.into())];
                let Ok(g) = (unsafe {
                    // The seam already owns the winding->D2D mapping; reuse it rather
                    // than naming a raw constant a second time.
                    f.CreateGeometryGroup(convert::fill_mode(FillRule::EvenOdd), &parts)
                }) else { return };
                g.into()
            } else {
                el.into()
            };
            let params = D2D1_LAYER_PARAMETERS {
                contentBounds: D2D_RECT_F {
                    left: f32::MIN, top: f32::MIN, right: f32::MAX, bottom: f32::MAX,
                },
                geometricMask: unsafe { std::mem::transmute_copy(&mask) },
                maskAntialiasMode: D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
                maskTransform: Matrix3x2::identity(),
                opacity: 1.0,
                opacityBrush: std::mem::ManuallyDrop::new(None),
                layerOptions: D2D1_LAYER_OPTIONS_NONE,
            };
            let w2 = st.width * 2.0;
            let ss = Self::stroke_style_on(rt, &st, w2);
            unsafe {
                rt.PushLayer(&params, None);
                rt.DrawEllipse(&e, &b, w2 as f32, ss.as_ref());
                rt.PopLayer();
            }
        });
    }

    /// NESTED, ARBITRARY-PATH CLIP. D2D has no cheap form: `PushAxisAlignedClip`
    /// takes rects only, so an arbitrary path needs a LAYER -- one offscreen
    /// clear, render and blend-back per call. B1 priced it and today's traffic
    /// is four call sites, all stroke-alignment, nesting depth 1.
    ///
    /// The contract has no `unclip`: a clip is undone by the enclosing
    /// `pop_state`, which is why the pop is recorded on the current frame.
    fn clip(&mut self, path: &[PathCommand], winding: FillRule) {
        let Ok(f) = (unsafe { self.rt().GetFactory() }) else { return };
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
        unsafe { self.rt().PushLayer(&params, None) };
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
                // ⛔ THE RETURN VALUE IS NO LONGER DISCARDED. `draw_fast_run`
                // has always answered `bool`; dropping it made an unresolvable
                // family draw nothing and say nothing — the silent-drop class,
                // in the one op nobody had driven end to end.
                if !text::draw_fast_run(&self.rt(), &b, font, *size, t, *letter_spacing, *x, *y) {
                    self.text_refusal =
                        Some("text run not drawn: the font could not be resolved");
                }
            }
            // PlacedGlyphs is PH3 shaping and unbuilt. It is recorded as a
            // refusal for the same reason: a mode that draws nothing must not
            // be counted as a frame that drew.
            TextRun::PlacedGlyphs { .. } => {
                self.text_refusal = Some("text run not drawn: PlacedGlyphs mode not built");
            }
        }
    }

    /// A6: open the MASK bracket. Everything drawn until the matching pop is
    /// mask content and lands on its own surface, never on the body.
    ///
    /// ⛔ THE LEDGER LINE THAT USED TO LIVE HERE IS KEPT, because a trail that
    /// goes cold costs more than a comment: this site once cited "option C,
    /// 2026-07-30" while the summons cited "option (a)". ONE OBJECT, TWO LABELS
    /// -- both pre-ratification working names for the element-bracket ruling,
    /// never in disagreement. The ledger carries ONE name now: AMENDMENT A6,
    /// ratified 2026-08-27. Neither prior label is used again.
    fn push_mask_layer(&mut self, mask: Mask) {
        match self.open_surface() {
            Some((brt, rt)) => self.masks.push(MaskTarget { brt, rt, law: mask }),
            // Same law as a failed layer open: a mask surface that could not be
            // made must NOT leave its content drawing onto the body, where it
            // would render as an extra shape rather than as a mask.
            None => self.failed_layers += 1,
        }
    }

    /// Close the mask bracket and HAND THE LAW TO THE ENCLOSING LAYER, which
    /// applies it when it composites.
    ///
    /// ⚠️ IF NO LAYER IS OPEN THE MASK IS DROPPED, and that is A6's own shape
    /// rather than a shortcut: the law is defined as eating into an isolated
    /// body buffer, so a mask with no layer around it has nothing to eat. The
    /// corpus never does this; `a_mask_outside_a_layer_is_not_silently_applied`
    /// is what keeps that true.
    fn pop_mask_layer(&mut self) {
        let Some(m) = self.masks.pop() else {
            if self.failed_layers > 0 { self.failed_layers -= 1; }
            return;
        };
        unsafe { let _ = m.rt.EndDraw(None, None); }
        let Ok(bmp) = (unsafe { m.brt.GetBitmap() }) else { return };
        if let Some(layer) = self.layers.last_mut() {
            layer.mask = Some((bmp, m.law));
        }
    }

    /// A6: open a fresh transparent surface in the parent's coordinate frame.
    ///
    /// A RENDER-TARGET SWAP, NOT A `PushLayer`, and that is B1's finding kept
    /// rather than revisited: `D2D1_LAYER_PARAMETERS1` serves none of the three
    /// mask laws, so the layer had to be a real surface anyway. The device
    /// context makes it -- the QI that this rests on is driven by
    /// `the_wic_target_upgrades_to_a_device_context_...`, which runs first for
    /// exactly that reason.
    fn push_isolated_layer(&mut self, alpha: f64, blend: BlendMode) {
        match self.open_surface() {
            Some((brt, rt)) => {
                let saved = std::mem::take(&mut self.group_alphas);
                self.layers.push(LayerTarget {
                    brt, rt, alpha, blend,
                    saved_group_alphas: saved,
                    mask: None,
                });
            }
            None => self.failed_layers += 1,
        }
    }

    /// A6 §3.3: flatten the layer and composite it as ONE primitive at
    /// effective alpha = (open-group product AT THE PUSH SITE) x the layer's own
    /// alpha -- applied ONCE. That is defect D-alpha's repair: the alpha must
    /// multiply into the inherited product, never replace it and never apply
    /// twice.
    fn pop_isolated_layer(&mut self) {
        if self.failed_layers > 0 {
            self.failed_layers -= 1;
            return;
        }
        let Some(layer) = self.layers.pop() else { return };
        // Restore the parent's product BEFORE computing the composite alpha --
        // the product that counts is the one at the push site.
        self.group_alphas = layer.saved_group_alphas;
        unsafe { let _ = layer.rt.EndDraw(None, None); }
        let Ok(body) = (unsafe { layer.brt.GetBitmap() }) else { return };

        // THE LAW EATS INTO THE FINISHED BODY HERE. If the layer carried a mask
        // bracket, the body is re-composited through it onto a scratch surface
        // first; the blit below then treats the result as any other layer.
        let bmp = match &layer.mask {
            None => body,
            Some((mask, law)) => match self.apply_mask(&body, mask, *law) {
                Some(masked) => masked,
                // ⛔ A MASK THAT CANNOT BE APPLIED MUST NOT COMPOSITE THE
                // UNMASKED BODY. That would draw the element at full extent --
                // exactly what the mask existed to prevent, and it would look
                // like a correct render of a different document.
                None => return,
            },
        };

        let parent = self.rt();
        let eff = self.effective_alpha(layer.alpha) as f32;
        // ⛔ THE BLIT RUNS AT IDENTITY. The layer's contents were already drawn
        // under the parent's transform, so compositing under it again would
        // apply the transform twice -- the same double-apply shape as D-alpha,
        // in geometry instead of opacity.
        let mut saved = Matrix3x2::identity();
        unsafe { parent.GetTransform(&mut saved) };
        unsafe { parent.SetTransform(&Matrix3x2::identity()) };
        // ⭐ A NON-NORMAL BLEND TAKES THE EFFECT GRAPH; Normal keeps the plain
        // blit it has always had.
        //
        // ⚠️ THE FALLBACK IS DELIBERATE AND IT IS NOT SILENT-BY-ACCIDENT. If the
        // graph cannot be built the layer still composites source-over, which is
        // the WRONG picture — but the alternative is an element that VANISHES,
        // and a missing element is the worse of the two failures here (it is the
        // one that reads as "the document is fine and empty"). Reaching this at
        // all means a device fault, not a routing decision: `replay`'s
        // declared-gap report is what tells a caller which modes are supported,
        // and it answers before a frame is ever drawn.
        let blended = layer.blend != BlendMode::Normal
            && self.composite_blended(&parent, &bmp, eff, layer.blend);
        if !blended {
            unsafe {
                parent.DrawBitmap(
                    &bmp,
                    None,
                    eff,
                    D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,
                    None,
                );
            }
        }
        unsafe { parent.SetTransform(&saved) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::painter::direct2d::device::HeadlessTarget;
    use crate::geometry::element::{LineCap, LineJoin};

    /// ⭐ THE PRECONDITION FOR A6 IN THIS BACKEND, DRIVEN BEFORE ANYTHING IS
    /// BUILT ON IT.
    ///
    /// `clip()`'s own comment says the `D2D1_LAYER_PARAMETERS1` variant "belongs
    /// to ID2D1DeviceContext, which the WIC target can be QueryInterface'd to
    /// (B1 route (a)) -- needed for masks later". **Later is now**, and the whole
    /// A6 design for this backend rests on that QI succeeding: the device context
    /// is what supplies `PushLayer` with an `opacityBrush`, `DrawImage`, and the
    /// effect graph (luminance-to-alpha, invert, blend) that the three mask laws
    /// and the `multiply` composite need.
    ///
    /// ⛔ IT IS A COMMENT, NOT A MEASUREMENT, UNTIL IT IS RUN. If this QI fails
    /// on the headless WIC target then the routed acceptance is unreachable by
    /// this route and that is a finding for the council, not something to
    /// discover halfway through an implementation. So it is a test, and it runs
    /// first.
    ///
    /// The second assertion is the one that matters for the mask work:
    /// `CreateCompatibleRenderTarget` is how an isolated layer gets its own
    /// surface in the parent's frame, and a device context that cannot make one
    /// would push the layer design back to a full second WIC target.
    #[test]
    fn the_wic_target_upgrades_to_a_device_context_and_can_make_a_compatible_target() {
        use windows::core::Interface;
        use windows::Win32::Graphics::Direct2D::ID2D1DeviceContext;

        let t = HeadlessTarget::new(64, 64).expect("target");

        let dc: ID2D1DeviceContext = t
            .target()
            .cast()
            .expect("B1 route (a): the WIC render target must QI to ID2D1DeviceContext --                      the A6 mask laws and the multiply composite have no other route here");

        // The isolated-layer surface. Same size and DPI as the parent by
        // default, which is exactly A6's "parent's coordinate frame and
        // rasterization scale".
        let compat = unsafe { dc.CreateCompatibleRenderTarget(None, None, None, Default::default()) }
            .expect("an isolated layer needs its own surface in the parent's frame");

        // A compatible target is only useful if its bitmap can be read back out
        // to composite. Assert the accessor, not merely the creation.
        let _bmp = unsafe { compat.GetBitmap() }
            .expect("the layer's bitmap is what pop_isolated_layer composites");
    }

    /// ⭐ THE SECOND PRECONDITION — CAN THIS TARGET RUN AN EFFECT GRAPH AT ALL?
    ///
    /// The three A6 mask laws lower onto effects: luminance_clip_in needs
    /// `CLSID_D2D1LuminanceToAlpha` then a SOURCE_IN composite; alpha_clip_out
    /// needs DESTINATION_OUT; alpha_reveal_outside_bbox needs an invert or its
    /// equivalent. All three constants exist in windows-rs -- I checked -- and
    /// **that is not the same as them working HERE.**
    ///
    /// ⛔ D2D EFFECTS NORMALLY WANT A D3D-BACKED DEVICE. This backend's target is
    /// a SOFTWARE WIC bitmap: it QIs to `ID2D1DeviceContext` (proven by the
    /// sibling test) but a QI is not a capability. If `CreateEffect` refuses on a
    /// WIC-backed context, the luminance law has no effect route here and the
    /// mask work needs a different pipeline -- which is a finding for the
    /// council, and one worth having BEFORE the pipeline is written, not after.
    ///
    /// Same reasoning as the device-context probe: a constant that exists is a
    /// lookup that succeeded, and a lookup that succeeds is not the thing found.
    #[test]
    fn the_wic_device_context_can_build_the_mask_effect_graph() {
        use windows::core::Interface;
        use windows::Win32::Graphics::Direct2D::{
            ID2D1DeviceContext, CLSID_D2D1LuminanceToAlpha,
        };

        let t = HeadlessTarget::new(32, 32).expect("target");
        let dc: ID2D1DeviceContext = t.target().cast().expect("device context");

        let effect = unsafe { dc.CreateEffect(&CLSID_D2D1LuminanceToAlpha) };
        match effect {
            Ok(_) => { /* the luminance law has its route */ }
            Err(e) => panic!(
                "CreateEffect(LuminanceToAlpha) refused on the WIC-backed device                  context: {e:?}. The luminance mask law has no effect route on                  this target -- report it, do not work around it silently."
            ),
        }
    }

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

    // -- ROW EG(2): THE GRADIENT HOLE, CLOSED -------------------------------
    //
    // ⭐ jas NAMED THIS BY READING, ON THE OTHER BACKEND, BEFORE I MEASURED IT:
    // "Nothing in the corpus compares gradient pixels, so picking the wrong one
    // would never go red." The Direct2D census confirmed it as a number -- ALL
    // SIX gradient mutants survived the whole 2,732-test native suite.
    //
    // ⛔ THE SPANS ARE DELIBERATELY NARROWER THAN THE SURFACE. D2D clamps
    // outside the gradient span (D2D1_EXTEND_MODE_CLAMP), so a pixel beyond the
    // span carries the stop colour EXACTLY. Sampling inside the ramp instead
    // would mean asserting an interpolated value, and an interpolated value is
    // not exactly representable in 8 bits -- the trap that cost this lane a
    // WARP-vs-hardware false green once already.

    fn stops_rb() -> Vec<crate::painter::ColorStop> {
        vec![
            crate::painter::ColorStop { offset: 0.0, color: Color::rgb(1.0, 0.0, 0.0) },
            crate::painter::ColorStop { offset: 1.0, color: Color::rgb(0.0, 0.0, 1.0) },
        ]
    }

    /// A linear gradient runs from its START to its END, in that order and
    /// along the axis its endpoints describe.
    #[test]
    fn a_linear_gradient_runs_from_its_start_point_to_its_end_point() {
        let g = Brush::Linear(crate::painter::LinearGradient {
            x0: 4.0, y0: 8.0, x1: 12.0, y1: 8.0, stops: stops_rb(),
        });
        let buf = draw(16, 16, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 16.0, h: 16.0 }, &g, 1.0)
        });
        // BGRA. Left of the span clamps to the first stop, right of it the last.
        assert_eq!(px(&buf, 16, 1, 8), [0, 0, 255, 255], "before the span: the FIRST stop");
        assert_eq!(px(&buf, 16, 14, 8), [255, 0, 0, 255], "after it: the LAST stop");
        // ⛔ AND THE SPAN STARTS WHERE x0 SAYS. The two clamp assertions above
        // hold for ANY span inside [4,12], so on their own they cannot see a
        // start point read from the wrong field -- a mutant that took X from
        // `y0` survived exactly them. x = 3 is still clamped and x = 4 is not:
        // that pair pins the edge itself.
        assert_eq!(px(&buf, 16, 3, 8), [0, 0, 255, 255], "x=3 is outside the span");
        assert_ne!(px(&buf, 16, 4, 8), [0, 0, 255, 255],
                   "x=4 IS the span's start, so the ramp has begun there");
        // ⛔ AND THE AXIS: the ramp is horizontal, so a vertical move must not
        // change the colour. Without this, reading x from y passes the two
        // assertions above on a gradient running the wrong way.
        assert_eq!(px(&buf, 16, 1, 2), px(&buf, 16, 1, 13),
                   "a horizontal ramp is constant down a column");
    }

    /// A radial gradient is centred on its OUTER circle and carries the inner
    /// circle's offset -- the two are different fields and swapping them is a
    /// plausible picture.
    #[test]
    fn a_radial_gradient_uses_the_outer_radius_and_the_origin_offset() {
        let g = Brush::Radial(crate::painter::RadialGradient {
            x0: 5.0, y0: 8.0, r0: 0.0, x1: 8.0, y1: 8.0, r1: 6.0, stops: stops_rb(),
        });
        let buf = draw(16, 16, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 16.0, h: 16.0 }, &g, 1.0)
        });
        // Outside r1 = 6 from (8,8): clamped to the last stop, exactly.
        assert_eq!(px(&buf, 16, 0, 0), [255, 0, 0, 255], "beyond the outer radius");
        // ⛔ THE OFFSET ORIGIN MAKES THE FIELD ASYMMETRIC. The focus sits LEFT
        // of centre, so the ramp is stretched to its right: a point equally far
        // either side of (8,8) is NOT the same colour. Zero the offset and this
        // is the assertion that fails.
        // ⚠️ "REDDER ON THE LEFT" IS NOT ENOUGH, MEASURED: with the offset
        // zeroed the field is still redder on the left of this sample pair,
        // just less so, and that mutant survived the weaker assertion. What
        // distinguishes them is WHERE THE FOCUS SITS -- the reddest point is at
        // x = 5 (the inner circle) and NOT at the centre.
        let focus = px(&buf, 16, 5, 8)[0];
        let centre = px(&buf, 16, 8, 8)[0];
        assert!(focus < centre,
                "the focus at x=5 is nearer the first stop than the centre is;                  zero the origin offset and the centre becomes the extreme                  (focus {focus} vs centre {centre})");
    }

    /// The paint alpha multiplies every gradient STOP, exactly as it multiplies
    /// a solid colour.
    #[test]
    fn a_gradient_honours_the_paint_alpha() {
        let g = Brush::Linear(crate::painter::LinearGradient {
            x0: 4.0, y0: 8.0, x1: 12.0, y1: 8.0, stops: stops_rb(),
        });
        let opaque = draw(16, 16, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 16.0, h: 16.0 }, &g, 1.0)
        });
        let half = draw(16, 16, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 16.0, h: 16.0 }, &g, 0.5)
        });
        assert_eq!(px(&opaque, 16, 1, 8)[3], 255, "the control is opaque");
        assert_eq!(px(&half, 16, 1, 8)[3], 128,
                   "half alpha reaches the STOPS, not only solid brushes");
    }

    /// ⛔ GRADIENTS INTERPOLATE IN sRGB (`D2D1_GAMMA_2_2`), NOT LINEARLY.
    ///
    /// The file already called this "a divergence pin, not a default" -- CSS
    /// interpolates gamma-encoded and `D2D1_GAMMA_1_0` does not, so the wrong
    /// one is a visibly different ramp on every gradient the app draws. **It
    /// was a pin in prose only: the census mutant that swapped it survived all
    /// 2,732 tests.**
    ///
    /// ⚠️ A THRESHOLD, NOT AN EQUALITY, AND DELIBERATELY SO. A gradient midpoint
    /// is an interpolated value and not exactly representable in 8 bits, so
    /// pinning the exact byte would be the WARP-vs-hardware trap this lane has
    /// already paid for once. Measured here: sRGB gives 144 at the midpoint and
    /// linear gives 197 -- about fifty apart, so a threshold between them is
    /// robust to a device that rounds differently.
    #[test]
    fn a_gradient_interpolates_in_srgb_and_not_linearly() {
        let g = Brush::Linear(crate::painter::LinearGradient {
            x0: 4.0, y0: 8.0, x1: 12.0, y1: 8.0, stops: stops_rb(),
        });
        let buf = draw(16, 16, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 16.0, h: 16.0 }, &g, 1.0)
        });
        let mid = px(&buf, 16, 8, 8)[0];
        assert!(mid < 170,
                "sRGB interpolation puts the midpoint near 144; LINEAR puts it                  near 197 (got {mid})");
    }

    // -- ROW EG(2b): THE CENSUS SURVIVORS, CLOSED ---------------------------
    //
    // Each arm below exists because a named mutant lived through the whole
    // native suite. The census script (`scripts/d2d_mutation_census.sh`) is what
    // found them and is what re-checks them.

    /// ⛔ THE TRANSLUCENT-COLOUR FORM — jas's own category name, and the one
    /// that is invisible while every fixture is opaque.
    ///
    /// `Color` carries its own alpha and the paint alpha MULTIPLIES it. Replace
    /// that multiply with an assignment and nothing reds, because `1.0 * a ==
    /// a` for every opaque colour any other arm draws. Two translucent halves
    /// give a quarter, and only a quarter distinguishes the two rules.
    #[test]
    fn a_translucent_colour_multiplies_with_the_paint_alpha() {
        let half_blue = Brush::Solid(Color::new(0.0, 0.0, 1.0, 0.5));
        let buf = draw(16, 16, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 16.0, h: 16.0 }, &half_blue, 0.5)
        });
        assert_eq!(px(&buf, 16, 8, 8)[3], 64,
                   "0.5 colour x 0.5 paint = 0.25, not 0.5 and not 1.0");
    }

    /// ⛔ A CLOSED PATH'S CLOSING EDGE IS STROKED. A fill closes an open figure
    /// implicitly, so only a STROKE can see this -- which is why the mutant that
    /// ended every figure OPEN survived a suite full of fills.
    #[test]
    fn a_closed_path_strokes_its_closing_edge() {
        let tri = vec![
            PathCommand::MoveTo { x: 3.0, y: 3.0 },
            PathCommand::LineTo { x: 13.0, y: 3.0 },
            PathCommand::LineTo { x: 13.0, y: 13.0 },
            PathCommand::ClosePath,
        ];
        let st = StrokeStyle {
            width: 3.0, cap: LineCap::Butt, join: LineJoin::Miter,
            miter: 10.0, dash: vec![],
        };
        let buf = draw(16, 16, |p| p.stroke_path(&tri, &red(), &st, 1.0));
        // The two drawn edges, as a control that the path reached the sink.
        assert_eq!(px(&buf, 16, 8, 3), [0, 0, 255, 255], "the top edge");
        assert_eq!(px(&buf, 16, 13, 8), [0, 0, 255, 255], "the right edge");
        // ⛔ THE HYPOTENUSE IS THE CLOSING EDGE, drawn only because the figure
        // is CLOSED. Leave it open and this pixel is empty.
        assert_eq!(px(&buf, 16, 8, 8), [0, 0, 255, 255],
                   "the closing edge back to the start");
    }

    /// ⛔ A QUADRATIC'S CONTROL POINT BENDS IT. Point the control at the
    /// endpoint and the curve becomes a straight line -- a plausible shape, and
    /// one no arm could see, because nothing compared a curved pixel.
    #[test]
    fn a_quadratic_bends_towards_its_control_point() {
        let curve = vec![
            PathCommand::MoveTo { x: 2.0, y: 14.0 },
            PathCommand::QuadTo { x1: 8.0, y1: 0.0, x: 14.0, y: 14.0 },
            PathCommand::ClosePath,
        ];
        let buf = draw(16, 16, |p| p.fill_path(&curve, FillRule::NonZero, &red(), 1.0));
        // Under the arch, which the straight-line degenerate case never reaches.
        assert_eq!(px(&buf, 16, 8, 9), [0, 0, 255, 255],
                   "the control at y=0 lifts the curve well above the chord");
    }

    /// ⛔ EVERY BLEND MODE IS ITS OWN MAPPING. The suite covered Multiply and
    /// ColorBurn, so Darken -> Lighten survived: an untested arm of a match is
    /// a mapping nothing checks.
    #[test]
    fn a_darken_group_takes_the_darker_of_the_two() {
        let buf = draw(16, 16, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 16.0, h: 16.0 },
                        &Brush::Solid(Color::rgb(0.2, 0.2, 0.2)), 1.0);
            p.push_group(1.0, BlendMode::Darken);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 16.0, h: 16.0 },
                        &Brush::Solid(Color::rgb(0.8, 0.8, 0.8)), 1.0);
            p.pop_group();
        });
        let v = px(&buf, 16, 8, 8)[0];
        assert!(v < 128,
                "Darken keeps the DARKER backdrop (0.2); Lighten would take                  0.8 and land near 204 (got {v})");
    }

    /// ⛔ A ROUND JOIN IS NOT A MITER JOIN. Every stroke fixture in this file
    /// used `LineJoin::Miter`, which maps to `MITER_OR_BEVEL` -- so forcing that
    /// constant changed nothing anywhere and the mutant lived.
    ///
    /// A right-angle corner stroked thickly: a miter fills the outer square
    /// corner, a round join cuts it away.
    #[test]
    fn a_round_join_rounds_the_corner_a_miter_would_fill() {
        let elbow = vec![
            PathCommand::MoveTo { x: 2.0, y: 8.0 },
            PathCommand::LineTo { x: 8.0, y: 8.0 },
            PathCommand::LineTo { x: 8.0, y: 14.0 },
        ];
        let mk = |join| StrokeStyle {
            width: 6.0, cap: LineCap::Butt, join, miter: 10.0, dash: vec![],
        };
        let mitred = draw(16, 16, |p| p.stroke_path(&elbow, &red(), &mk(LineJoin::Miter), 1.0));
        let round = draw(16, 16, |p| p.stroke_path(&elbow, &red(), &mk(LineJoin::Round), 1.0));

        // The outer corner of the elbow is (11,5) for a 6-wide stroke.
        assert_eq!(px(&mitred, 16, 10, 6), [0, 0, 255, 255], "a miter fills the corner");
        assert_ne!(px(&round, 16, 10, 6), px(&mitred, 16, 10, 6),
                   "and a ROUND join does not -- the join must reach the backend");
    }

    /// ⛔ THE MITER LIMIT IS A NUMBER THE CALLER CHOOSES. Every fixture used the
    /// default 10, so hardcoding 10 changed nothing. A spike sharp enough to
    /// exceed a limit of 1 gets bevelled instead, and that is visible.
    #[test]
    fn a_miter_limit_bevels_a_spike_too_sharp_to_keep() {
        let spike = vec![
            PathCommand::MoveTo { x: 2.0, y: 13.0 },
            PathCommand::LineTo { x: 8.0, y: 3.0 },
            PathCommand::LineTo { x: 14.0, y: 13.0 },
        ];
        let mk = |miter| StrokeStyle {
            width: 3.0, cap: LineCap::Butt, join: LineJoin::Miter, miter, dash: vec![],
        };
        let kept = draw(16, 16, |p| p.stroke_path(&spike, &red(), &mk(10.0), 1.0));
        let cut = draw(16, 16, |p| p.stroke_path(&spike, &red(), &mk(1.0), 1.0));
        assert_ne!(px(&kept, 16, 8, 1), px(&cut, 16, 8, 1),
                   "a limit of 1 bevels the spike a limit of 10 keeps");
    }

    /// ⛔ D2D DASH LENGTHS ARE MULTIPLES OF THE STROKE WIDTH, not absolute.
    /// The contract's `dash` is absolute (canvas semantics), so it must be
    /// divided by the emitted width -- and at width 1 that division is the
    /// identity, which is why a mutant replacing the divisor with 1.0 survived
    /// a suite whose only dashed fixture was one pixel wide.
    #[test]
    fn a_dash_pattern_is_scaled_by_a_width_other_than_one() {
        let line = vec![
            PathCommand::MoveTo { x: 0.0, y: 8.0 },
            PathCommand::LineTo { x: 16.0, y: 8.0 },
        ];
        let st = StrokeStyle {
            width: 4.0, cap: LineCap::Butt, join: LineJoin::Miter,
            miter: 10.0, dash: vec![4.0, 4.0],
        };
        let buf = draw(16, 16, |p| p.stroke_path(&line, &red(), &st, 1.0));
        // 4-on/4-off at width 4 is ONE multiple on, one off: ink 0..4, gap 4..8.
        assert_eq!(px(&buf, 16, 1, 8), [0, 0, 255, 255], "the first dash");
        assert_eq!(px(&buf, 16, 6, 8), [0, 0, 0, 0], "and the first gap");
        // Undivided, the pattern would be 4 DEVICE units at width 4 = 16 units
        // on, which paints the whole line and never reaches a gap.
    }

    /// An out-of-range paint alpha paints an opaque colour rather than
    /// something wild. The trait does not forbid a caller passing one.
    ///
    /// ⚠️ **THIS ARM DOES NOT KILL THE UNCLAMPED MUTANT, AND SAYING SO IS THE
    /// POINT.** I wrote it expecting to, and measured otherwise: removing
    /// `clamp(0.0, 1.0)` leaves this pixel identical, because D2D SATURATES a
    /// `D2D1_COLOR_F` alpha above 1 itself. So the clamp is genuinely
    /// unobservable at the pixel — a real equivalent mutant, established by
    /// trying to kill it rather than by arguing it away.
    ///
    /// The clamp stays: relying on a backend's saturation to hold a contract
    /// invariant is a promise D2D never made, and the next backend need not.
    #[test]
    fn an_out_of_range_paint_alpha_is_clamped_not_passed_through() {
        let buf = draw(16, 16, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 16.0, h: 16.0 },
                        &Brush::Solid(Color::new(0.0, 0.0, 1.0, 1.0)), 4.0)
        });
        assert_eq!(px(&buf, 16, 8, 8), [255, 0, 0, 255],
                   "alpha 4.0 clamps to 1.0 and paints an opaque blue");
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

    /// ⭐ ROW EG(1), THE PARTIAL-ARC RULING: **a partial arc is DRAWN AS THE
    /// ARC**, on every port.
    ///
    /// ⚰️ THIS ARM REPLACES A REFUSAL PIN, and the swap is the point. It used to
    /// read *"a partial arc must paint NOTHING"* and asserted an all-transparent
    /// buffer — a defensible pin when nothing could draw an arc, but it pinned
    /// the ABSENCE of a feature, so it would have gone on passing forever while
    /// the arc stayed undrawn.
    ///
    /// ⛔ WHAT SURVIVES FROM IT IS THE PART THAT WAS ALWAYS RIGHT: **never a
    /// full disc.** An arc silently closed into a disc is the "looks almost
    /// right" failure, and the assertion below still catches it — from the
    /// other side, by naming a pixel that must stay clear.
    ///
    /// The sweep 0→π on a y-down surface is the LOWER half. Three points, and
    /// each one is load-bearing: inside the sweep must paint, outside the sweep
    /// must not (that is the "never a disc" half), and outside the radius must
    /// not (or a bug that filled the bounding box would pass the first two).
    #[test]
    fn a_partial_arc_is_drawn_as_the_arc_and_never_as_a_full_disc() {
        let half = EllipseArc {
            cx: 8.0, cy: 8.0, rx: 6.0, ry: 6.0, rotation: 0.0,
            start: 0.0, end: std::f64::consts::PI, ccw: false,
        };
        let buf = draw(16, 16, |p| p.fill_ellipse_arc(&half, FillRule::NonZero, &red(), 1.0));

        assert_eq!(px(&buf, 16, 8, 11), [0, 0, 255, 255],
                   "inside the swept half: painted");
        assert_eq!(px(&buf, 16, 8, 5), [0, 0, 0, 0],
                   "the UNSWEPT half stays clear -- this is 'never a full disc'");
        assert_eq!(px(&buf, 16, 0, 15), [0, 0, 0, 0],
                   "and outside the radius stays clear, so a filled bbox cannot pass");
    }

    /// ⭐ ROW EG(1), THE STROKE HALF: **a stroked partial arc has no chord.**
    ///
    /// ⛔ THIS IS THE ARM THAT MAKES `close` EARN ITS PARAMETER. Filling a
    /// partial arc closes it with a line back to the start; stroking must not
    /// draw that line, or every partial arc wears a bar across its mouth. Both
    /// pictures are plausible in a display list and only one is right, so the
    /// difference is asserted in PIXELS rather than trusted to a flag.
    ///
    /// The chord of a 0→π sweep is the horizontal diameter at y = cy. A point
    /// ON that line but away from the arc itself must stay clear.
    #[test]
    fn a_stroked_partial_arc_draws_no_closing_chord() {
        let half = EllipseArc {
            cx: 8.0, cy: 8.0, rx: 6.0, ry: 6.0, rotation: 0.0,
            start: 0.0, end: std::f64::consts::PI, ccw: false,
        };
        // ⚠️ WIDTH 4, NOT 2, AND THE REASON IS ANTIALIASING. At width 2 the
        // band's edge falls inside the sample pixel and it reads [0,0,235,235]
        // -- 92% coverage, which is the arc being drawn correctly, not a
        // failure. A sample point must sit wholly INSIDE the ink for an
        // equality assertion to mean what it says.
        let st = StrokeStyle {
            width: 4.0, cap: LineCap::Butt, join: LineJoin::Miter,
            miter: 10.0, dash: vec![],
        };
        let buf = draw(16, 16, |p| {
            p.stroke_ellipse_arc(&half, &red(), &st, StrokeAlign::Center, 1.0)
        });

        // The arc itself, at its lowest point (cx, cy + r): the band spans
        // y 12..16, so this pixel is fully covered.
        assert_eq!(px(&buf, 16, 8, 14), [0, 0, 255, 255], "the arc is stroked");
        // ⛔ THE CHORD'S SEAT: mid-diameter, y = cy, well inside both endpoints.
        assert_eq!(px(&buf, 16, 8, 8), [0, 0, 0, 0],
                   "no closing chord -- a stroked arc is OPEN");
        // And the unswept half is still untouched.
        assert_eq!(px(&buf, 16, 8, 2), [0, 0, 0, 0], "the unswept half stays clear");
    }

    /// ⭐ A SWEEP GREATER THAN π, which is a DIFFERENT arc from the same two
    /// endpoints — the case `arcSize` exists to disambiguate.
    ///
    /// ⛔ WRITTEN BECAUSE A MUTANT SURVIVED. Forcing `arcSize` to SMALL passed
    /// every other arm here, because the half-circle fixture sweeps exactly π —
    /// the boundary, where SMALL and LARGE describe the same arc. *An arm that
    /// exercises a feature in only one configuration cannot see an error in the
    /// others*, and π was the one configuration that could not tell.
    ///
    /// 0 → 3π/2 clockwise on a y-down surface leaves the UPPER-RIGHT quadrant
    /// unswept. Its chord runs (8,2)→(14,8), i.e. the line y = x − 6.
    #[test]
    fn a_sweep_past_half_a_turn_takes_the_long_way_round() {
        let three_quarters = EllipseArc {
            cx: 8.0, cy: 8.0, rx: 6.0, ry: 6.0, rotation: 0.0,
            start: 0.0, end: 3.0 * std::f64::consts::FRAC_PI_2, ccw: false,
        };
        let buf = draw(16, 16, |p| {
            p.fill_ellipse_arc(&three_quarters, FillRule::NonZero, &red(), 1.0)
        });

        // Inside the swept three-quarters, well clear of the chord.
        assert_eq!(px(&buf, 16, 5, 11), [0, 0, 255, 255], "the long way IS swept");
        // ⛔ (12,4) is inside the circle and ABOVE the chord (4 < 12−6), so it
        // lies in the unswept quadrant. Take the SHORT arc instead and this
        // pixel is the one that fills.
        assert_eq!(px(&buf, 16, 12, 4), [0, 0, 0, 0],
                   "the unswept quadrant stays clear -- a SMALL arc would fill it");
    }

    /// ⭐ A ROTATED PARTIAL ARC HONOURS ITS ROTATION.
    ///
    /// ⛔ WRITTEN BECAUSE A MUTANT SURVIVED: zeroing `rotationAngle` passed all
    /// 79 arms in this backend. Rotation matters MORE than it looks, because
    /// `full_ellipse` refuses a rotated arc — so since row EG(1) every rotated
    /// ellipse reaches the screen through this builder and nothing was
    /// asserting the angle it drew at.
    ///
    /// rx 6 / ry 2 rotated a quarter turn puts the LONG axis vertical. At three
    /// pixels below centre the shape is ~1.7px wide either side of x = 8; drop
    /// the rotation and the same point is far outside a 2px-tall ellipse.
    #[test]
    fn a_rotated_partial_arc_is_drawn_at_its_rotation() {
        let rotated = EllipseArc {
            cx: 8.0, cy: 8.0, rx: 6.0, ry: 2.0,
            rotation: std::f64::consts::FRAC_PI_2,
            start: 0.0, end: std::f64::consts::PI, ccw: false,
        };
        let buf = draw(16, 16, |p| {
            p.fill_ellipse_arc(&rotated, FillRule::NonZero, &red(), 1.0)
        });
        // The shape is a narrow vertical sliver: only x = 6,7 carry ink.
        assert_eq!(px(&buf, 16, 7, 11), [0, 0, 255, 255], "the sliver is drawn");
        // ⛔ AND THE PIXEL THAT ACTUALLY DISCRIMINATES. My first attempt
        // asserted only the line above and the mutant SURVIVED: x = 7 is
        // painted either way. Measured, the zeroed-rotation case makes D2D
        // rescale the radii to reach endpoints it otherwise cannot, and it
        // floods x = 0..7 on every row. This point is the difference.
        assert_eq!(px(&buf, 16, 3, 8), [0, 0, 0, 0],
                   "far from the sliver -- an unrotated fit floods this");
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

    /// ⭐ THE A6 ALPHA LAW, IN PIXELS — defect D-alpha's ratified repair.
    ///
    /// ⛔ THE CROSS-BACKEND FRAMING THAT USED TO BE HERE IS REMOVED, and its
    /// removal is the point rather than tidying. This doc cited a
    /// "pixel-equal to Canvas2D" acceptance that the helm WITHDREW on 08/29:
    /// it named a canvas-lane fixture and a comparison no path in this repo can
    /// execute. A criterion must be written in the terms of the seat that must
    /// execute it — and a retired criterion left quoted in a live comment is a
    /// criterion the next reader inherits as current. (Citation ageing, banked
    /// 08/28: a cited claim becomes the citing document's own the moment it is
    /// written down.)
    ///
    /// What this test asserts stands entirely on its own: **this backend obeys
    /// the ratified A6 alpha law.** It says nothing about any other backend and
    /// never did.
    ///
    /// A 0.5 group around a 0.5 layer around an opaque red fill must land at
    /// **0.25**, i.e. alpha ~= 64/255. Three ways to be wrong and the number
    /// separates all of them:
    ///
    /// * **0.5 (~128)** -- the layer alpha REPLACED the inherited product
    ///   instead of multiplying into it. That was HEAD's behaviour.
    /// * **0.125 (~32)** -- the layer alpha applied TWICE, once into the body
    ///   and again at the blit. That was the other half of D-alpha.
    /// * **1.0 (~255)** -- no alpha applied at all.
    ///
    /// ⛔ A SINGLE-VALUE ASSERT WOULD BE WEAKER THAN IT LOOKS: 0.25 is what you
    /// get from the correct law AND from any implementation that happens to
    /// multiply two halves somewhere. The nesting is what makes it diagnostic --
    /// the group and the layer carry the SAME 0.5, so a replace-bug and a
    /// multiply-bug land on visibly different numbers rather than colliding.
    #[test]
    fn the_layer_alpha_multiplies_into_the_group_product_exactly_once() {
        let t = HeadlessTarget::new(8, 8).unwrap();
        unsafe { t.target().BeginDraw() };
        unsafe {
            t.target().Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 0.0 }));
        }
        {
            let mut p = Direct2DPainter::new(t.target());
            p.push_group(0.5, BlendMode::Normal);
            p.push_isolated_layer(0.5, BlendMode::Normal);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 8.0 }, &red(), 1.0);
            p.pop_isolated_layer();
            p.pop_group();
        }
        unsafe { t.target().EndDraw(None, None).unwrap() };

        let a = px(&t.read_bgra().expect("readback"), 8, 4, 4)[3] as i32;
        assert!(
            (a - 64).abs() <= 3,
            "A6 alpha law: 0.5 group x 0.5 layer x opaque fill must be ~64/255, got {a}.              ~128 = the layer alpha replaced the product (HEAD's D-alpha);              ~32 = it applied twice; ~255 = it did not apply."
        );
    }

    /// ⭐ SUPERSEDES `masks_refuse_loudly_pending_the_a6_implementation`.
    ///
    /// That test asserted the refusal MESSAGE, and it was right to: while the
    /// backend could not do masks, the message was the contract, and pinning it
    /// kept a third ledger label from appearing. **The contract has changed --
    /// masks are implemented -- so the test is replaced rather than deleted, and
    /// its replacement asserts the opposite fact against the same op.**
    ///
    /// ⛔ AND IT ASSERTS PIXELS, NOT ABSENCE OF A PANIC. A mask bracket that
    /// opened and did nothing would also not panic. So: a red body, a mask that
    /// covers only the left half, `AlphaClipOut` -- the covered half must be
    /// GONE and the uncovered half must REMAIN. Either alone passes on a broken
    /// implementation: "all gone" is a mask that ate everything, "all there" is
    /// a mask that did nothing.
    #[test]
    fn a_clip_out_mask_removes_the_covered_half_and_keeps_the_rest() {
        let t = HeadlessTarget::new(16, 16).unwrap();
        unsafe { t.target().BeginDraw() };
        unsafe {
            t.target().Clear(Some(&D2D1_COLOR_F { r: 0.0, g: 0.0, b: 0.0, a: 0.0 }));
        }
        {
            let mut p = Direct2DPainter::new(t.target());
            p.push_isolated_layer(1.0, BlendMode::Normal);
            // body: red over the whole surface
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 16.0, h: 16.0 }, &red(), 1.0);
            // mask: opaque over the LEFT half only
            p.push_mask_layer(Mask::AlphaClipOut);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 16.0 }, &red(), 1.0);
            p.pop_mask_layer();
            p.pop_isolated_layer();
        }
        unsafe { t.target().EndDraw(None, None).unwrap() };

        let buf = t.read_bgra().expect("readback");
        let left = px(&buf, 16, 4, 8);
        let right = px(&buf, 16, 12, 8);
        assert_eq!(left[3], 0, "clip_out must REMOVE the masked half, got alpha {}", left[3]);
        assert!(right[3] > 200, "and must KEEP the unmasked half, got alpha {}", right[3]);
    }

    // -----------------------------------------------------------------------
    // (b) THE ISOLATED-LAYER BLEND — closing a6_blend.json
    // -----------------------------------------------------------------------

    fn solid_rgb(r: f64, g: f64, b: f64) -> Brush {
        Brush::Solid(Color::new(r, g, b, 1.0))
    }

/// ⭐ ROW CM's LAST GOLDEN: a NON-ISOLATED group blend.
    ///
    /// `group_blend.json` is the one scene that never reached the presented
    /// surface. Its blend rides `push_group`, which is **non-isolated** by
    /// contract — the mode applies to every descendant primitive against the
    /// LIVE backdrop, one primitive at a time. That is what makes it a different
    /// job from the isolated-layer blend (#75): one composite there, a composite
    /// PER PRIMITIVE here.
    ///
    /// `multiply(0.8, 0.5) = 0.40` → 102, exactly as the isolated arm asserts.
    /// The two wrong answers are both plausible pictures: **128** means the
    /// blend was ignored, **204** means the source was dropped.
    #[test]
    fn a_non_isolated_group_multiplies_each_primitive_against_the_backdrop() {
        let buf = draw(4, 4, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.8, 0.8, 0.8), 1.0);
            p.push_group(1.0, BlendMode::Multiply);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.5, 0.5, 0.5), 1.0);
            p.pop_group();
        });
        let [b, g, r, a] = px(&buf, 4, 1, 1);
        assert_eq!(a, 255, "the composite stays opaque, got alpha {a}");
        for (name, v) in [("b", b), ("g", g), ("r", r)] {
            assert!((v as i32 - 102).abs() <= 2,
                    "{name}: multiply(0.8,0.5) must be ~102, got {v} -- 128 means \
                     the blend was IGNORED, 204 means the source was dropped");
        }
    }

    /// ⛔ THE PROPERTY THAT MAKES A GROUP A GROUP AND NOT A LAYER: it is
    /// NON-ISOLATED, so each primitive blends against what the PREVIOUS one
    /// left, not against the group's own start.
    ///
    /// Two multiplies of 0.5 over an 0.8 backdrop compound to
    /// `0.8 · 0.5 · 0.5 = 0.20` → 51. An ISOLATED layer would flatten the two
    /// first and give `0.8 · 0.5 = 0.40` → 102. **That difference is the whole
    /// reason `push_group` could not simply reuse `push_isolated_layer`'s
    /// machinery**, and it is asserted rather than described.
    #[test]
    fn overlapping_primitives_in_a_blended_group_compound_rather_than_isolate() {
        let buf = draw(4, 4, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.8, 0.8, 0.8), 1.0);
            p.push_group(1.0, BlendMode::Multiply);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.5, 0.5, 0.5), 1.0);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.5, 0.5, 0.5), 1.0);
            p.pop_group();
        });
        let [b, _, _, a] = px(&buf, 4, 1, 1);
        assert_eq!(a, 255);
        assert!((b as i32 - 51).abs() <= 3,
                "two multiplies must COMPOUND to ~51 (0.20), got {b} -- ~102 means \
                 the group isolated and flattened them first, which is a layer, \
                 not a group");
    }

    /// ⛔ THE NON-COMMUTATIVE ARM, and it exists because the Multiply-only suite
    /// on the isolated path let a swapped-input mutant live. ColorBurn:
    /// `1 − min(1, (1−Cb)/Cs)`. Backdrop 0.8 over source 0.5 → 0.60 → 153;
    /// swapped → 0.375 → 96.
    #[test]
    fn a_non_commutative_group_blend_pins_which_input_is_the_backdrop() {
        let buf = draw(4, 4, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.8, 0.8, 0.8), 1.0);
            p.push_group(1.0, BlendMode::ColorBurn);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.5, 0.5, 0.5), 1.0);
            p.pop_group();
        });
        let [b, _, _, _] = px(&buf, 4, 1, 1);
        assert!((b as i32 - 153).abs() <= 3,
                "colour-burn(backdrop 0.8, source 0.5) must be ~153, got {b} -- \
                 ~96 means INPUTS 0 AND 1 ARE SWAPPED");
    }

    /// ⛔ GROUP ALPHA STILL COMPOUNDS UNDER A BLEND. `push_group`'s alpha is a
    /// flat multiply into every descendant's paint alpha (contract D3), and the
    /// blend must not swallow it: a 0.5-alpha multiply group over an opaque 0.8
    /// backdrop lands halfway between the backdrop (204) and the blend (102).
    #[test]
    fn a_blended_groups_alpha_still_multiplies_into_its_primitives() {
        let buf = draw(4, 4, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.8, 0.8, 0.8), 1.0);
            p.push_group(0.5, BlendMode::Multiply);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.5, 0.5, 0.5), 1.0);
            p.pop_group();
        });
        let [b, _, _, a] = px(&buf, 4, 1, 1);
        assert_eq!(a, 255, "an opaque backdrop stays opaque");
        assert!((b as i32 - 153).abs() <= 4,
                "a 0.5-alpha multiply group must land ~153, got {b} -- 102 means \
                 the group alpha was DROPPED, 204 means the blend was");
    }

    /// A group blend must not paint outside its primitives' coverage.
    #[test]
    fn a_group_blend_is_confined_to_what_it_actually_draws() {
        let buf = draw(8, 4, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 4.0 }, &solid_rgb(0.8, 0.8, 0.8), 1.0);
            p.push_group(1.0, BlendMode::Multiply);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.5, 0.5, 0.5), 1.0);
            p.pop_group();
        });
        let [left, _, _, _] = px(&buf, 8, 1, 1);
        let [right, _, _, ra] = px(&buf, 8, 6, 1);
        assert!((left as i32 - 102).abs() <= 2, "covered half blends, got {left}");
        assert!((right as i32 - 204).abs() <= 2,
                "uncovered half must be untouched backdrop, got {right}");
        assert_eq!(ra, 255);
    }

    /// ⛔⛔ A NESTED GROUP RESETS THE BLEND — THE INNERMOST WINS — and this arm
    /// exists because a mutation pass proved nothing else asserted it.
    ///
    /// The seam contract is explicit: *"a nested `push_group` resets it and leaf
    /// primitives inherit the innermost group's blend — matching today, where a
    /// Group's own mode is overridden by its children."* A mutant reading the
    /// OUTERMOST blend instead passed all 3,183 tests, because every other arm
    /// here opens exactly one group.
    ///
    /// Outer `Multiply`, inner `Screen`, over an 0.8 backdrop with an 0.5
    /// source:
    /// * screen (correct) — `1 − (1−0.8)(1−0.5)` = **0.90** → 230
    /// * multiply (the outer, wrong) — **0.40** → 102
    ///
    /// 128 levels apart, so no tolerance can confuse them.
    #[test]
    fn a_nested_group_resets_the_blend_and_the_innermost_wins() {
        let buf = draw(4, 4, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.8, 0.8, 0.8), 1.0);
            p.push_group(1.0, BlendMode::Multiply);
            p.push_group(1.0, BlendMode::Screen);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.5, 0.5, 0.5), 1.0);
            p.pop_group();
            p.pop_group();
        });
        let [b, _, _, _] = px(&buf, 4, 1, 1);
        assert!((b as i32 - 230).abs() <= 3,
                "the INNER screen must win (~230), got {b} -- ~102 means the                  OUTER multiply was used, which is the wrong end of the stack");
    }

    /// And popping the inner group RESTORES the outer one, rather than clearing
    /// the stack — the other half of "nested".
    #[test]
    fn popping_an_inner_group_restores_the_outer_blend() {
        let buf = draw(4, 4, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.8, 0.8, 0.8), 1.0);
            p.push_group(1.0, BlendMode::Multiply);
            p.push_group(1.0, BlendMode::Screen);
            p.pop_group(); // back to Multiply
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.5, 0.5, 0.5), 1.0);
            p.pop_group();
        });
        let [b, _, _, _] = px(&buf, 4, 1, 1);
        assert!((b as i32 - 102).abs() <= 3,
                "after popping the inner Screen the outer Multiply applies (~102),                  got {b} -- ~128 means the stack was cleared, ~230 means Screen                  outlived its group");
    }

    /// ⛔ AND A NORMAL GROUP MUST NOT TAKE THE NEW PATH AT ALL. It has no blend
    /// to apply, and routing it through a per-primitive composite would pay a
    /// surface allocation per draw for nothing.
    #[test]
    fn a_normal_group_still_draws_straight_through() {
        let buf = draw(4, 4, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.8, 0.8, 0.8), 1.0);
            p.push_group(1.0, BlendMode::Normal);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.5, 0.5, 0.5), 1.0);
            p.pop_group();
        });
        let [b, _, _, _] = px(&buf, 4, 1, 1);
        assert!((b as i32 - 128).abs() <= 2,
                "a Normal group is plain source-over (~128), got {b}");
    }

    /// ⭐ THE BLEND ARITHMETIC, ASSERTED AGAINST THE SPEC AND NOT AGAINST
    /// WHATEVER D2D HAPPENS TO RETURN.
    ///
    /// `multiply(Cb, Cs) = Cb x Cs` (W3C compositing §blend-multiply). An opaque
    /// 0.8 backdrop under an opaque 0.5 source must give 0.40 — **not** 0.5
    /// (which is what a `DrawBitmap` source-over produces, i.e. the blend being
    /// silently ignored) and not 0.8 (the source being dropped).
    ///
    /// ⛔ THE TWO WRONG ANSWERS ARE BOTH PLAUSIBLE PICTURES, which is exactly
    /// why this asserts a NUMBER rather than "something changed".
    #[test]
    fn an_isolated_layer_multiplies_against_the_backdrop() {
        let buf = draw(4, 4, |p| {
            // Backdrop: opaque 0.8 grey, drawn straight onto the base target.
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.8, 0.8, 0.8), 1.0);
            // Source: an isolated layer holding opaque 0.5 grey, multiplied in.
            p.push_isolated_layer(1.0, BlendMode::Multiply);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.5, 0.5, 0.5), 1.0);
            p.pop_isolated_layer();
        });
        let [b, g, r, a] = px(&buf, 4, 1, 1);
        assert_eq!(a, 255, "the composite must stay opaque, got alpha {a}");
        // 0.8 * 0.5 = 0.40 -> 102. Tolerance 2 for the 8-bit round trip.
        for (name, v) in [("b", b), ("g", g), ("r", r)] {
            assert!((v as i32 - 102).abs() <= 2,
                    "{name}: multiply(0.8,0.5) must be ~102 (0.40), got {v} \
                     -- 128 means the blend was IGNORED, 204 means the source was dropped");
        }
    }

    /// ⛔⛔ THE ARM THAT GIVES THE INPUT ORDER TEETH — AND IT EXISTS BECAUSE A
    /// MUTATION PASS PROVED THE COMMENT WAS NOT A GUARD.
    ///
    /// `composite_blended` says, in as many words, that swapping inputs 0 and 1
    /// "is invisible for Multiply and Screen — both commutative — and WRONG for
    /// ColorBurn, Overlay, HardLight". I then wrote a Multiply-only test suite.
    /// Measured 2026-09-01: **a mutant that swapped the two inputs passed all
    /// 22 tests.** I had written the warning and left nothing able to enforce it.
    ///
    /// ColorBurn is NOT commutative: `B(Cb,Cs) = 1 - min(1, (1-Cb)/Cs)`.
    /// * right way round — `Cb=0.8, Cs=0.5` → `1 - 0.2/0.5` = **0.60** → 153
    /// * swapped        — `Cb=0.5, Cs=0.8` → `1 - 0.5/0.8` = **0.375** → 96
    ///
    /// Fifty-seven levels apart, so the arm cannot be satisfied by the wrong
    /// pairing. ⇒ **A comment naming a hazard does not test for it; only an
    /// asymmetric fixture does.**
    #[test]
    fn a_non_commutative_blend_pins_which_input_is_the_backdrop() {
        let buf = draw(4, 4, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.8, 0.8, 0.8), 1.0);
            p.push_isolated_layer(1.0, BlendMode::ColorBurn);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.5, 0.5, 0.5), 1.0);
            p.pop_isolated_layer();
        });
        let [b, _, _, a] = px(&buf, 4, 1, 1);
        assert_eq!(a, 255);
        assert!((b as i32 - 153).abs() <= 3,
                "colour-burn(backdrop 0.8, source 0.5) must be ~153 (0.60), got {b} \
                 -- ~96 means INPUTS 0 AND 1 ARE SWAPPED, 204 means the blend was ignored");
    }

    /// ⛔ THE CONTROL. The SAME scene with `Normal` must NOT be 102 — otherwise
    /// the arm above could be passing on a painter that multiplies everything,
    /// or on one that ignores the mode entirely and happens to land there.
    #[test]
    fn the_same_layer_under_normal_is_not_the_multiplied_answer() {
        let buf = draw(4, 4, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.8, 0.8, 0.8), 1.0);
            p.push_isolated_layer(1.0, BlendMode::Normal);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.5, 0.5, 0.5), 1.0);
            p.pop_isolated_layer();
        });
        let [b, _, _, a] = px(&buf, 4, 1, 1);
        assert_eq!(a, 255);
        // Normal = source over = the source itself, 0.5 -> 128.
        assert!((b as i32 - 128).abs() <= 2,
                "Normal must still be plain source-over (~128), got {b}");
    }

    /// ⛔ THE LAYER'S OWN ALPHA STILL APPLIES ONCE, UNDER A BLEND TOO. D-alpha's
    /// repair must not be undone by the new path: a half-alpha multiply layer
    /// over an opaque backdrop is the blended colour composited at 0.5, i.e.
    /// halfway between the backdrop (204) and the blend result (102) -> ~153.
    #[test]
    fn a_blended_layers_alpha_is_applied_once_not_twice_and_not_dropped() {
        let buf = draw(4, 4, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.8, 0.8, 0.8), 1.0);
            p.push_isolated_layer(0.5, BlendMode::Multiply);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.5, 0.5, 0.5), 1.0);
            p.pop_isolated_layer();
        });
        let [b, _, _, a] = px(&buf, 4, 1, 1);
        assert_eq!(a, 255, "opaque backdrop stays opaque");
        assert!((b as i32 - 153).abs() <= 3,
                "0.5-alpha multiply over 0.8 must be ~153; got {b} \
                 -- 102 means the alpha was DROPPED, ~178 means it applied twice");
    }

    /// A blend must not paint OUTSIDE the layer's own coverage. The backdrop is
    /// full-bleed and the layer covers only the left half; the right half must
    /// be untouched backdrop.
    #[test]
    fn a_blend_is_confined_to_the_layers_coverage() {
        let buf = draw(8, 4, |p| {
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 8.0, h: 4.0 }, &solid_rgb(0.8, 0.8, 0.8), 1.0);
            p.push_isolated_layer(1.0, BlendMode::Multiply);
            p.fill_rect(Rect { x: 0.0, y: 0.0, w: 4.0, h: 4.0 }, &solid_rgb(0.5, 0.5, 0.5), 1.0);
            p.pop_isolated_layer();
        });
        let [left, _, _, _] = px(&buf, 8, 1, 1);
        let [right, _, _, ra] = px(&buf, 8, 6, 1);
        assert!((left as i32 - 102).abs() <= 2, "covered half blends, got {left}");
        assert!((right as i32 - 204).abs() <= 2,
                "uncovered half must be untouched backdrop (~204), got {right}");
        assert_eq!(ra, 255);
    }
}

