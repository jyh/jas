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
}

impl<'a> Direct2DPainter<'a> {
    pub fn new(rt: &'a ID2D1RenderTarget) -> Self {
        Self {
            base_rt: rt,
            frames: Vec::new(),
            group_alphas: Vec::new(),
            layers: Vec::new(),
            masks: Vec::new(),
            failed_layers: 0,
        }
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
        unsafe { self.rt().CreateSolidColorBrush(&col, None) }
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
        unsafe { self.rt().CreateGradientStopCollection(&v, D2D1_GAMMA_2_2, D2D1_EXTEND_MODE_CLAMP) }.ok()
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
                unsafe { self.rt().CreateLinearGradientBrush(&props, None, &sc) }.ok().map(|b| b.into())
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
                unsafe { self.rt().CreateRadialGradientBrush(&props, None, &sc) }.ok().map(|b| b.into())
            }
        }
    }

    fn stroke_style(&self, s: &StrokeStyle, emit_width: f64) -> Option<ID2D1StrokeStyle> {
        let props = convert::stroke_properties(s);
        let dashes = convert::dash_multiples(&s.dash, emit_width);
        let factory = unsafe { self.rt().GetFactory() }.ok()?;
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
    /// | `NonNormalGroupBlend` (a NON-ISOLATED group) | **NO — and it stays a declared gap** | a group's blend rides EVERY descendant primitive against the live backdrop, so it needs a per-primitive graph: a change to every draw method, not one composite. |
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
            C::IsolatedLayers | C::MaskLayers | C::NonNormalBlend => true,
            C::NonNormalGroupBlend => false,
        }
    }

    fn fill_rect(&mut self, rect: Rect, brush: &Brush, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        if let Some(b) = self.brush(brush, a) {
            unsafe { self.rt().FillRectangle(&d2d_rect(rect), &b) };
        }
    }

    fn stroke_rect(&mut self, rect: Rect, brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        if let Some(b) = self.brush(brush, a) {
            let ss = self.stroke_style(stroke, stroke.width);
            unsafe {
                self.rt().DrawRectangle(&d2d_rect(rect), &b, stroke.width as f32, ss.as_ref())
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
        let Ok(f) = (unsafe { self.rt().GetFactory() }) else { return };
        if let Ok(Some(g)) = geometry::build(&f, path, winding) {
            unsafe { self.rt().FillGeometry(&g, &b, None) };
        }
    }

    fn stroke_path(&mut self, path: &[PathCommand], brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        let Some(b) = self.brush(brush, a) else { return };
        let Ok(f) = (unsafe { self.rt().GetFactory() }) else { return };
        // A stroked path carries no fill rule; NonZero is the contract default
        // and the rule is irrelevant to stroking.
        if let Ok(Some(g)) = geometry::build(&f, path, FillRule::NonZero) {
            let ss = self.stroke_style(stroke, stroke.width);
            unsafe { self.rt().DrawGeometry(&g, &b, stroke.width as f32, ss.as_ref()) };
        }
    }

    fn fill_ellipse_arc(&mut self, arc: &EllipseArc, _winding: FillRule, brush: &Brush, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        let Some(b) = self.brush(brush, a) else { return };
        let Some(e) = full_ellipse(arc) else { return };
        unsafe { self.rt().FillEllipse(&e, &b) };
    }

    fn stroke_ellipse_arc(&mut self, arc: &EllipseArc, brush: &Brush, stroke: &StrokeStyle, paint_alpha: f64) {
        let a = self.effective_alpha(paint_alpha);
        let Some(b) = self.brush(brush, a) else { return };
        let Some(e) = full_ellipse(arc) else { return };
        let ss = self.stroke_style(stroke, stroke.width);
        unsafe { self.rt().DrawEllipse(&e, &b, stroke.width as f32, ss.as_ref()) };
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
                text::draw_fast_run(&self.rt(), &b, font, *size, t, *letter_spacing, *x, *y);
            }
            _ => {}
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
