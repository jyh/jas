//! Canvas2D rendering of document elements.
//!
//! Draws the document onto an HTML <canvas> via web_sys::CanvasRenderingContext2d.

use std::cell::RefCell;

use wasm_bindgen::JsCast;
use web_sys::{CanvasRenderingContext2d, HtmlCanvasElement};

use crate::algorithms::calligraphic_outline::{calligraphic_outline, CalligraphicBrush};
use crate::document::artboard::{Artboard, ArtboardFill};
use crate::document::document::Document;
use crate::geometry::element::Visibility;
use crate::geometry::element::*;
use crate::geometry::measure::path_point_at_offset;
use crate::tools::tool::HANDLE_DRAW_SIZE;

// ---------------------------------------------------------------------------
// Brush library lookup (thread-local, set for the duration of render())
// ---------------------------------------------------------------------------
//
// The Calligraphic outliner needs brush parameters keyed by the
// jas:stroke-brush "<library>/<brush>" slug carried on each PathElem.
// Threading brush_libraries through every canvas helper signature would
// be invasive in this 2000-line file, so we mirror the thread_local
// pattern used by `interpreter::doc_primitives` for Document.

thread_local! {
    static CURRENT_BRUSH_LIBS: RefCell<serde_json::Value> =
        RefCell::new(serde_json::Value::Null);
}

/// Install `libs` as the current render's brush library registry.
/// Returns a guard whose Drop restores the previous registry.
pub struct BrushLibsGuard {
    prior: serde_json::Value,
}

impl Drop for BrushLibsGuard {
    fn drop(&mut self) {
        let prior = std::mem::replace(&mut self.prior, serde_json::Value::Null);
        CURRENT_BRUSH_LIBS.with(|c| *c.borrow_mut() = prior);
    }
}

pub fn register_brush_libraries(libs: serde_json::Value) -> BrushLibsGuard {
    let prior = CURRENT_BRUSH_LIBS.with(|c| c.replace(libs));
    BrushLibsGuard { prior }
}

/// Look up a brush by its "<library>/<brush>" slug in the current
/// thread-local registry. Returns None if the slug is missing or
/// malformed, so the caller can fall back to the plain native stroke
/// render (null-on-missing per BRUSHES.md §Selection model).
fn lookup_brush(slug: &str) -> Option<serde_json::Value> {
    let sep = slug.find('/')?;
    let (lib_id, brush_slug) = slug.split_at(sep);
    let brush_slug = &brush_slug[1..]; // skip the '/'
    CURRENT_BRUSH_LIBS.with(|c| {
        let libs = c.borrow();
        let lib = libs.get(lib_id)?;
        let brushes = lib.get("brushes")?.as_array()?;
        brushes
            .iter()
            .find(|b| b.get("slug").and_then(|v| v.as_str()) == Some(brush_slug))
            .cloned()
    })
}

/// If the brush JSON describes a Calligraphic brush, extract its
/// angle / roundness / size into the native struct. Other brush types
/// return None in Phase 1 — the renderer falls back to plain stroke
/// (matches BRUSHES.md Phase 1 "Calligraphic only" scope).
fn calligraphic_from_json(brush: &serde_json::Value) -> Option<CalligraphicBrush> {
    if brush.get("type").and_then(|v| v.as_str()) != Some("calligraphic") {
        return None;
    }
    Some(CalligraphicBrush {
        angle: brush.get("angle").and_then(|v| v.as_f64()).unwrap_or(0.0),
        roundness: brush.get("roundness").and_then(|v| v.as_f64()).unwrap_or(100.0),
        size: brush.get("size").and_then(|v| v.as_f64()).unwrap_or(5.0),
    })
}

/// Draw `elem` as a brushed stroke: compute the Calligraphic outline
/// polygon and fill it with the element's stroke colour. Returns true
/// if the brushed render succeeded; false when the brush is missing or
/// not Calligraphic (the caller then falls back to the plain stroke
/// render).
fn draw_brushed_path(
    ctx: &CanvasRenderingContext2d,
    elem: &PathElem,
    outline: bool,
) -> bool {
    if outline {
        // Outline (wireframe) mode ignores brushes; caller handles.
        return false;
    }
    let slug = match elem.stroke_brush.as_deref() {
        Some(s) => s,
        None => return false,
    };
    let brush = match lookup_brush(slug) {
        Some(b) => b,
        None => return false, // null-on-missing fallback
    };
    let cal = match calligraphic_from_json(&brush) {
        Some(c) => c,
        None => return false, // non-Calligraphic types → plain stroke fallback
    };
    let pts = calligraphic_outline(&elem.d, &cal);
    if pts.len() < 3 {
        return true; // degenerate — emit nothing, but we did "handle" it
    }
    let color = match elem.stroke.as_ref() {
        Some(s) => css_color(&s.color),
        None => "#000000".to_string(),
    };
    ctx.set_fill_style_str(&color);
    ctx.begin_path();
    ctx.move_to(pts[0].0, pts[0].1);
    for p in &pts[1..] {
        ctx.line_to(p.0, p.1);
    }
    ctx.close_path();
    ctx.fill();
    true
}

// ---------------------------------------------------------------------------
// Color conversion
// ---------------------------------------------------------------------------

fn css_color(c: &Color) -> String {
    let (r, g, b, a) = c.to_rgba();
    if a >= 1.0 {
        format!(
            "rgb({},{},{})",
            (r * 255.0) as u8,
            (g * 255.0) as u8,
            (b * 255.0) as u8,
        )
    } else {
        format!(
            "rgba({},{},{},{})",
            (r * 255.0) as u8,
            (g * 255.0) as u8,
            (b * 255.0) as u8,
            a,
        )
    }
}

/// Map a BlendMode to the Canvas2D `globalCompositeOperation` string.
/// Canvas2D natively supports all 16 separable / non-separable blend modes
/// used by the Opacity panel; Normal maps to the default `source-over`.
fn blend_mode_css(mode: BlendMode) -> &'static str {
    match mode {
        BlendMode::Normal      => "source-over",
        BlendMode::Darken      => "darken",
        BlendMode::Multiply    => "multiply",
        BlendMode::ColorBurn   => "color-burn",
        BlendMode::Lighten     => "lighten",
        BlendMode::Screen      => "screen",
        BlendMode::ColorDodge  => "color-dodge",
        BlendMode::Overlay     => "overlay",
        BlendMode::SoftLight   => "soft-light",
        BlendMode::HardLight   => "hard-light",
        BlendMode::Difference  => "difference",
        BlendMode::Exclusion   => "exclusion",
        BlendMode::Hue         => "hue",
        BlendMode::Saturation  => "saturation",
        BlendMode::Color       => "color",
        BlendMode::Luminosity  => "luminosity",
    }
}

/// Build a CanvasGradient from a `Gradient` and the element's bounding box.
/// Returns None if the gradient is freeform (rendering deferred to a later
/// phase) or has fewer than 2 stops.
fn make_canvas_gradient(
    ctx: &CanvasRenderingContext2d,
    g: &Gradient,
    bx: f64, by: f64, bw: f64, bh: f64,
) -> Option<web_sys::CanvasGradient> {
    if g.stops.len() < 2 { return None; }
    let cg = match g.gtype {
        GradientType::Linear => {
            // Angle convention: 0° = left-to-right; positive rotates CCW.
            // Endpoints lie on the bbox boundary aligned with the angle.
            let cx = bx + bw / 2.0;
            let cy = by + bh / 2.0;
            let rad = g.angle * std::f64::consts::PI / 180.0;
            let half_diag = (bw * bw + bh * bh).sqrt() / 2.0;
            let dx = rad.cos() * half_diag;
            let dy = -rad.sin() * half_diag; // canvas y is down
            ctx.create_linear_gradient(cx - dx, cy - dy, cx + dx, cy + dy)
        }
        GradientType::Radial => {
            let cx = bx + bw / 2.0;
            let cy = by + bh / 2.0;
            let r = (bw.max(bh) / 2.0) * (g.aspect_ratio / 100.0).max(0.01);
            ctx.create_radial_gradient(cx, cy, 0.0, cx, cy, r).ok()?
        }
        GradientType::Freeform => return None,
    };
    for stop in &g.stops {
        let mut c = stop.color.with_alpha(stop.opacity / 100.0);
        // The opacity field is applied via alpha so a per-stop opacity of
        // 50 becomes a stop with an rgba color at 50% alpha.
        if stop.opacity == 100.0 {
            c = stop.color;
        }
        let _ = cg.add_color_stop((stop.location / 100.0) as f32, &css_color(&c));
    }
    Some(cg)
}

fn poly_bbox(pts: &[(f64, f64)]) -> (f64, f64, f64, f64) {
    if pts.is_empty() { return (0.0, 0.0, 0.0, 0.0); }
    let (mut x_min, mut y_min) = pts[0];
    let (mut x_max, mut y_max) = pts[0];
    for &(x, y) in &pts[1..] {
        if x < x_min { x_min = x; } if x > x_max { x_max = x; }
        if y < y_min { y_min = y; } if y > y_max { y_max = y; }
    }
    (x_min, y_min, x_max - x_min, y_max - y_min)
}

fn apply_fill(
    ctx: &CanvasRenderingContext2d, fill: Option<&Fill>,
    fill_gradient: Option<&Gradient>, bbox: (f64, f64, f64, f64),
) -> f64 {
    if let Some(g) = fill_gradient {
        let (bx, by, bw, bh) = bbox;
        if let Some(cg) = make_canvas_gradient(ctx, g, bx, by, bw, bh) {
            ctx.set_fill_style_canvas_gradient(&cg);
            return fill.map(|f| f.opacity).unwrap_or(1.0);
        }
    }
    match fill {
        Some(f) => {
            ctx.set_fill_style_str(&css_color(&f.color));
            f.opacity
        }
        None => {
            ctx.set_fill_style_str("transparent");
            1.0
        }
    }
}

/// Return value from apply_stroke: (opacity, alignment).
fn apply_stroke(ctx: &CanvasRenderingContext2d, stroke: Option<&Stroke>) -> (f64, StrokeAlign) {
    apply_stroke_with_gradient(ctx, stroke, None, (0.0, 0.0, 0.0, 0.0))
}

/// Phase 8: gradient-aware stroke. When `stroke_gradient` is set and
/// renderable, sets the context stroke style to a CanvasGradient
/// (within-stroke sub-mode only; along / across remain
/// `pending_renderer` per GRADIENT.md §Stroke sub-modes).
fn apply_stroke_with_gradient(
    ctx: &CanvasRenderingContext2d,
    stroke: Option<&Stroke>,
    stroke_gradient: Option<&Gradient>,
    bbox: (f64, f64, f64, f64),
) -> (f64, StrokeAlign) {
    match stroke {
        Some(s) => {
            if let Some(g) = stroke_gradient {
                let (bx, by, bw, bh) = bbox;
                if let Some(cg) = make_canvas_gradient(ctx, g, bx, by, bw, bh) {
                    ctx.set_stroke_style_canvas_gradient(&cg);
                } else {
                    ctx.set_stroke_style_str(&css_color(&s.color));
                }
            } else {
                ctx.set_stroke_style_str(&css_color(&s.color));
            }
            // Inside/outside use 2x width; the clip removes the unwanted half
            let effective_width = match s.align {
                StrokeAlign::Center => s.width,
                StrokeAlign::Inside | StrokeAlign::Outside => s.width * 2.0,
            };
            ctx.set_line_width(effective_width);
            ctx.set_line_cap(match s.linecap {
                LineCap::Butt => "butt",
                LineCap::Round => "round",
                LineCap::Square => "square",
            });
            ctx.set_line_join(match s.linejoin {
                LineJoin::Miter => "miter",
                LineJoin::Round => "round",
                LineJoin::Bevel => "bevel",
            });
            ctx.set_miter_limit(s.miter_limit);
            let da = s.dash_array();
            // When dash_align_anchors is on, the renderer expands the
            // dashed stroke into solid sub-paths via DashRenderer and
            // draws each as a solid stroke — so the platform's dash
            // attribute must be empty here. See DASH_ALIGN.md
            // §Algorithm. Per-shape callers branch on
            // s.dash_align_anchors to choose the dasher path.
            if !da.is_empty() && !s.dash_align_anchors {
                let js_array = js_sys::Array::new();
                for &v in da {
                    js_array.push(&wasm_bindgen::JsValue::from_f64(v));
                }
                ctx.set_line_dash(&js_array).ok();
            } else {
                ctx.set_line_dash(&js_sys::Array::new()).ok();
            }
            (s.opacity, s.align)
        }
        None => {
            ctx.set_stroke_style_str("transparent");
            ctx.set_line_width(0.0);
            (1.0, StrokeAlign::Center)
        }
    }
}

/// Stroke the current path with alignment clipping.
/// The current path must already be traced on the context.
/// For Inside, clips to the path fill area, strokes at 2x width (set by apply_stroke).
/// For Outside, clips to the inverse of the path (evenodd with large rect), strokes at 2x width.
/// For Center, just strokes normally.
fn stroke_aligned(ctx: &CanvasRenderingContext2d, align: StrokeAlign) {
    match align {
        StrokeAlign::Center => {
            ctx.stroke();
        }
        StrokeAlign::Inside => {
            // The current path is still on the context. Clip to it,
            // then stroke — only the inner half of the 2x-width stroke is visible.
            ctx.save();
            ctx.clip();
            ctx.stroke();
            ctx.restore();
        }
        StrokeAlign::Outside => {
            // The current path is still on the context. Add a huge rect
            // to the existing path (rect() doesn't clear it), then clip
            // with evenodd — this clips to everything OUTSIDE the shape.
            ctx.save();
            ctx.rect(-1e6, -1e6, 2e6, 2e6);
            // Call clip("evenodd") via js_sys since web-sys may not expose the overload
            let _ = js_sys::Reflect::apply(
                &js_sys::Function::from(wasm_bindgen::JsValue::from(
                    js_sys::Reflect::get(ctx, &wasm_bindgen::JsValue::from_str("clip")).unwrap()
                )),
                ctx,
                &js_sys::Array::of1(&wasm_bindgen::JsValue::from_str("evenodd")),
            );
            ctx.stroke();
            ctx.restore();
        }
    }
}

fn apply_transform(ctx: &CanvasRenderingContext2d, transform: Option<&Transform>) {
    if let Some(t) = transform {
        ctx.transform(t.a, t.b, t.c, t.d, t.e, t.f).ok();
    }
}

// ---------------------------------------------------------------------------
// Build path commands into canvas path
// ---------------------------------------------------------------------------

pub(crate) fn build_path(ctx: &CanvasRenderingContext2d, cmds: &[PathCommand]) {
    for cmd in cmds {
        match cmd {
            PathCommand::MoveTo { x, y } => ctx.move_to(*x, *y),
            PathCommand::LineTo { x, y } => ctx.line_to(*x, *y),
            PathCommand::CurveTo {
                x1, y1, x2, y2, x, y,
            } => ctx.bezier_curve_to(*x1, *y1, *x2, *y2, *x, *y),
            PathCommand::QuadTo { x1, y1, x, y } => {
                ctx.quadratic_curve_to(*x1, *y1, *x, *y)
            }
            PathCommand::ClosePath => ctx.close_path(),
            // Smooth curves and arcs: approximate as line to endpoint
            PathCommand::SmoothCurveTo { x, y, .. }
            | PathCommand::SmoothQuadTo { x, y }
            | PathCommand::ArcTo { x, y, .. } => ctx.line_to(*x, *y),
        }
    }
}

// ---------------------------------------------------------------------------
// Draw a single element
// ---------------------------------------------------------------------------

/// Configure `ctx` for an outline-mode draw of a shape: no fill, a
/// thin black stroke. The spec says "stroke of size 0"; in practice
/// a canvas stroke width of 0 renders nothing, so we use the minimum
/// visible width (1 pixel). This is the mode used for every non-Text
/// element when its effective visibility is [`Visibility::Outline`].
fn apply_outline_style(ctx: &CanvasRenderingContext2d) {
    ctx.set_stroke_style_str("rgb(0,0,0)");
    ctx.set_fill_style_str("transparent");
    ctx.set_line_width(1.0);
    ctx.set_line_cap("butt");
    ctx.set_line_join("miter");
    ctx.set_line_dash(&wasm_bindgen::JsValue::from(js_sys::Array::new())).ok();
    ctx.set_miter_limit(10.0);
}

fn draw_element(
    ctx: &CanvasRenderingContext2d,
    elem: &Element,
    ancestor_vis: Visibility,
    precision: f64,
) {
    // Opacity mask: when an element carries an active mask,
    // redirect rendering through the mask composite path. The plan
    // encodes which of the three supported composite strategies to
    // use. OPACITY.md §Rendering.
    if let Some(mask) = elem.common().mask.as_deref() {
        if let Some(plan) = mask_plan(mask) {
            draw_element_with_mask(ctx, elem, mask, plan, ancestor_vis, precision);
            return;
        }
    }
    draw_element_body(ctx, elem, ancestor_vis, precision);
}

// ---------------------------------------------------------------------------
// Opacity-mask compositing (OPACITY.md §Rendering)
// ---------------------------------------------------------------------------

/// How the mask subtree's rendered alpha is applied to the element.
/// Selected by [mask_plan] from the mask's ``clip`` and ``invert``
/// fields; consumed by [draw_element_with_mask].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum MaskPlan {
    /// Element clipped to the mask shape. ``destination-in`` applied
    /// on the full offscreen canvas. `clip: true, invert: false`.
    ClipIn,
    /// Element clipped to the *inverse* of the mask shape.
    /// ``destination-out`` on the full offscreen canvas. Covers
    /// both `clip: true, invert: true` and — for alpha-based masks
    /// — `clip: false, invert: true`, which collapse to the same
    /// output (`E * (1 - M)` everywhere) since the mask's
    /// "outside" region contributes zero alpha either way.
    ClipOut,
    /// `clip: false, invert: false`: element stays at full alpha
    /// outside the mask subtree's bounding box; ``destination-in``
    /// with the mask applies only inside the bbox via a clip path.
    /// OPACITY.md §Rendering.
    RevealOutsideBbox,
}

/// Pick a [MaskPlan] for the mask, or ``None`` when the mask is
/// inactive (``disabled: true``). The plan encodes how
/// [draw_element_with_mask] should composite the mask subtree
/// against the element body.
fn mask_plan(mask: &Mask) -> Option<MaskPlan> {
    if mask.disabled {
        return None;
    }
    Some(match (mask.clip, mask.invert) {
        (true, false) => MaskPlan::ClipIn,
        (true, true) => MaskPlan::ClipOut,
        // Alpha-based masks can't distinguish `clip: false,
        // invert: true` from `clip: true, invert: true` (both yield
        // `E * (1 - M)` when the mask's outside-region alpha is 0),
        // so route them through the same composite.
        (false, true) => MaskPlan::ClipOut,
        (false, false) => MaskPlan::RevealOutsideBbox,
    })
}

/// Return the transform that should be applied when rendering the
/// mask's subtree on top of the ancestor coord system. Track C
/// phase 3, OPACITY.md §Document model:
///
/// - ``linked: true``  — mask inherits the element's transform
///   (mask follows the element).
/// - ``linked: false`` — mask uses ``unlink_transform`` (the
///   element's transform captured at unlink time, frozen so the
///   mask stays fixed under subsequent element edits).
fn effective_mask_transform<'a>(
    mask: &'a Mask,
    elem: &'a Element,
) -> Option<&'a Transform> {
    if mask.linked {
        elem.transform()
    } else {
        mask.unlink_transform.as_ref()
    }
}

thread_local! {
    /// Reusable offscreen canvas for opacity-mask compositing.
    /// Created lazily on first use and resized to match the main
    /// canvas when the dimensions change. Kept as a module-level
    /// scratch buffer to avoid allocating a new DOM canvas per
    /// masked element per frame.
    static MASK_CANVAS: RefCell<Option<HtmlCanvasElement>> = const { RefCell::new(None) };
    /// Second scratch canvas, used to render the mask subtree in
    /// isolation before its alpha is promoted to luminance (see
    /// [promote_mask_to_luminance]). Only populated when the
    /// ClipIn path enters the luminance branch.
    static MASK_LUMA_CANVAS: RefCell<Option<HtmlCanvasElement>> = const { RefCell::new(None) };
}

/// Read the six-component current transform from a Canvas2D
/// context via JS reflection on ``currentTransform``. Returns
/// ``None`` when the property isn't present or its fields aren't
/// numeric (which means we fall back to identity on the caller's
/// offscreen ctx — a reasonable degradation).
fn read_ctx_transform(
    ctx: &CanvasRenderingContext2d,
) -> Option<(f64, f64, f64, f64, f64, f64)> {
    let t = js_sys::Reflect::get(ctx, &wasm_bindgen::JsValue::from_str("currentTransform")).ok()?;
    let a = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("a")).ok()?.as_f64()?;
    let b = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("b")).ok()?.as_f64()?;
    let c = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("c")).ok()?.as_f64()?;
    let d = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("d")).ok()?.as_f64()?;
    let e = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("e")).ok()?.as_f64()?;
    let f = js_sys::Reflect::get(&t, &wasm_bindgen::JsValue::from_str("f")).ok()?.as_f64()?;
    Some((a, b, c, d, e, f))
}

/// Obtain (or lazily create) the scratch mask canvas, resized to
/// ``w x h``. Returns the canvas together with its 2D context.
/// Returns ``None`` if the DOM isn't reachable (e.g., non-browser
/// host or the canvas can't be created). Node is *not* appended
/// to the document — it lives only in memory.
fn get_mask_scratch(w: u32, h: u32) -> Option<(HtmlCanvasElement, CanvasRenderingContext2d)> {
    scratch_from_cell(&MASK_CANVAS, w, h)
}

/// Second scratch canvas, used by the luminance-based mask path
/// to render the mask subtree in isolation before its alpha is
/// replaced by luminance.
fn get_mask_luma_scratch(w: u32, h: u32) -> Option<(HtmlCanvasElement, CanvasRenderingContext2d)> {
    scratch_from_cell(&MASK_LUMA_CANVAS, w, h)
}

fn scratch_from_cell(
    cell: &'static std::thread::LocalKey<RefCell<Option<HtmlCanvasElement>>>,
    w: u32, h: u32,
) -> Option<(HtmlCanvasElement, CanvasRenderingContext2d)> {
    let canvas: HtmlCanvasElement = cell.with(|c| -> Option<HtmlCanvasElement> {
        if let Some(v) = c.borrow().clone() {
            return Some(v);
        }
        let window = web_sys::window()?;
        let doc = window.document()?;
        let el = doc.create_element("canvas").ok()?;
        let v: HtmlCanvasElement = el.unchecked_into();
        *c.borrow_mut() = Some(v.clone());
        Some(v)
    })?;
    if canvas.width() != w {
        canvas.set_width(w);
    }
    if canvas.height() != h {
        canvas.set_height(h);
    }
    let ctx: CanvasRenderingContext2d = canvas
        .get_context("2d").ok()??.unchecked_into();
    Some((canvas, ctx))
}

/// Promote the alpha channel of ``ctx``'s pixels within the given
/// device-space rectangle from raw alpha to luminance-scaled
/// alpha: ``A' = A * (0.299*R + 0.587*G + 0.114*B) / 255``. This
/// matches PDF §11's soft-mask convention — a black-opaque mask
/// reads as fully transparent, a white-opaque mask as fully
/// opaque, and a gray-opaque mask as partially opaque. Restricted
/// to the given rect for performance (typical masks occupy a
/// small fraction of the canvas).
///
/// Returns ``true`` on success. On ``None`` returns (ImageData
/// unavailable) the caller falls back to alpha-based masking so
/// the user's mask still has *some* effect, just not the
/// luminance-weighted one.
fn promote_mask_to_luminance(
    ctx: &CanvasRenderingContext2d,
    dx: i32, dy: i32, dw: u32, dh: u32,
) -> Option<()> {
    if dw == 0 || dh == 0 {
        return Some(());
    }
    let image_data = ctx
        .get_image_data(dx as f64, dy as f64, dw as f64, dh as f64)
        .ok()?;
    let data = image_data.data();
    let mut bytes: Vec<u8> = data.to_vec();
    promote_bytes_to_luminance(&mut bytes);
    let clamped = wasm_bindgen::Clamped(bytes.as_slice());
    let new_data = web_sys::ImageData::new_with_u8_clamped_array_and_sh(
        clamped, dw, dh,
    ).ok()?;
    ctx.put_image_data(&new_data, dx as f64, dy as f64).ok()?;
    Some(())
}

/// Replace each RGBA pixel's alpha channel with
/// ``A' = A * (0.299*R + 0.587*G + 0.114*B) / 255``. Pure
/// function, testable without a live canvas.
fn promote_bytes_to_luminance(bytes: &mut [u8]) {
    let mut i = 0;
    while i + 3 < bytes.len() {
        let r = bytes[i] as f64;
        let g = bytes[i + 1] as f64;
        let b = bytes[i + 2] as f64;
        let a = bytes[i + 3] as f64;
        // ITU-R BT.601 luma weights; integers would be faster but
        // the f64 form is clear and the inner loop is
        // getImageData-bound anyway.
        let lum = 0.299 * r + 0.587 * g + 0.114 * b;
        let new_alpha = (lum * a / 255.0).round().clamp(0.0, 255.0) as u8;
        bytes[i + 3] = new_alpha;
        i += 4;
    }
}

/// Apply the ``ClipIn`` luminance composite on an offscreen
/// canvas that already holds the rendered element body. Returns
/// ``true`` on success, ``false`` when any intermediate step
/// fails so the caller can fall back to alpha-based compositing.
/// ``off_ctx`` must carry the mask's effective transform applied
/// on top of the main world transform.
///
/// Steps:
///   1. Render the mask subtree in isolation onto the luma
///      scratch canvas (a fresh transparent buffer, same
///      transform as ``off_ctx``).
///   2. Promote that scratch's pixels from raw alpha to
///      luminance-scaled alpha (black-opaque → fully transparent,
///      white-opaque → fully opaque, gray → partial).
///   3. Blit the luma scratch onto the element-body buffer with
///      ``destination-in``; the luminance alpha clips the element.
fn apply_clip_in_luminance(
    off_ctx: &CanvasRenderingContext2d,
    w: u32,
    h: u32,
    mask: &Mask,
    ancestor_vis: Visibility,
    precision: f64,
) -> bool {
    let (luma_canvas, luma_ctx) = match get_mask_luma_scratch(w, h) {
        Some(p) => p,
        None => return false,
    };
    luma_ctx.set_transform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0).ok();
    luma_ctx.set_global_composite_operation("source-over").ok();
    luma_ctx.set_global_alpha(1.0);
    luma_ctx.clear_rect(0.0, 0.0, w as f64, h as f64);
    if let Some((a, b, c, d, e, f)) = read_ctx_transform(off_ctx) {
        luma_ctx.set_transform(a, b, c, d, e, f).ok();
    }
    draw_element(&luma_ctx, &mask.subtree, ancestor_vis, precision);
    if promote_mask_to_luminance(&luma_ctx, 0, 0, w, h).is_none() {
        return false;
    }
    off_ctx.save();
    off_ctx.set_transform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0).ok();
    off_ctx.set_global_composite_operation("destination-in").ok();
    let _ = off_ctx.draw_image_with_html_canvas_element(&luma_canvas, 0.0, 0.0);
    off_ctx.restore();
    true
}

/// Render ``elem`` on the main ``ctx`` with its opacity mask
/// composited in. The element body is drawn to a scratch
/// offscreen canvas at the same world transform as the main ctx;
/// the mask's subtree is then composited according to ``plan``.
/// The scratch canvas is finally copied onto the main ctx at
/// device coordinates.
fn draw_element_with_mask(
    ctx: &CanvasRenderingContext2d,
    elem: &Element,
    mask: &Mask,
    plan: MaskPlan,
    ancestor_vis: Visibility,
    precision: f64,
) {
    let main_canvas = ctx.canvas();
    let (w, h) = match &main_canvas {
        Some(c) => (c.width(), c.height()),
        None => {
            // No canvas reachable — fall back to the no-mask path.
            draw_element_body(ctx, elem, ancestor_vis, precision);
            return;
        }
    };
    if w == 0 || h == 0 {
        return;
    }
    let (off_canvas, off_ctx) = match get_mask_scratch(w, h) {
        Some(pair) => pair,
        None => {
            draw_element_body(ctx, elem, ancestor_vis, precision);
            return;
        }
    };

    // Reset offscreen state and clear any prior content.
    off_ctx.set_transform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0).ok();
    off_ctx.set_global_composite_operation("source-over").ok();
    off_ctx.set_global_alpha(1.0);
    off_ctx.clear_rect(0.0, 0.0, w as f64, h as f64);

    // Copy the main ctx's current world transform onto the offscreen
    // ctx so ``elem`` renders at the same screen position it would
    // on the main canvas. web-sys 0.3 doesn't expose
    // ``getTransform()`` / ``DOMMatrix`` under the enabled features,
    // so read ``currentTransform`` via JS reflection — the object
    // has ``a``..``f`` number fields matching the 2D matrix.
    if let Some((a, b, c, d, e, f)) = read_ctx_transform(ctx) {
        off_ctx.set_transform(a, b, c, d, e, f).ok();
    }

    // Pass 1: draw the element body (skipping the mask dispatch so
    // we don't recurse into ourselves) onto the offscreen canvas.
    draw_element_body(&off_ctx, elem, ancestor_vis, precision);

    // Pass 2: apply the mask's effective transform (per
    // ``effective_mask_transform``), then composite the mask
    // subtree against the element body.
    off_ctx.save();
    if let Some(t) = effective_mask_transform(mask, elem) {
        off_ctx.transform(t.a, t.b, t.c, t.d, t.e, t.f).ok();
    }
    match plan {
        MaskPlan::ClipIn => {
            // Luminance-based soft-mask composite. The mask subtree
            // is rendered to a separate scratch, its alpha is
            // replaced by the per-pixel luminance (so a black
            // opaque mask reads as fully transparent and a white
            // opaque mask reads as fully opaque), and then the
            // result is drawn onto the element buffer with
            // ``destination-in``. Matches PDF §11's soft-mask
            // convention. OPACITY.md §Rendering.
            //
            // If any step of the luminance path fails (ImageData
            // unavailable, zero-size canvas, …) we fall back to
            // the alpha-based composite so the user still sees
            // *something*.
            let fell_back = !apply_clip_in_luminance(
                &off_ctx, w, h, mask, ancestor_vis, precision,
            );
            if fell_back {
                off_ctx.set_global_composite_operation("destination-in").ok();
                draw_element(&off_ctx, &mask.subtree, ancestor_vis, precision);
            }
        }
        MaskPlan::ClipOut => {
            // `destination-out` over the whole canvas — the mask
            // shape erases the element.
            off_ctx.set_global_composite_operation("destination-out").ok();
            draw_element(&off_ctx, &mask.subtree, ancestor_vis, precision);
        }
        MaskPlan::RevealOutsideBbox => {
            // `clip: false, invert: false`: the element keeps full
            // alpha outside the mask subtree's bounding box, and is
            // clipped to the mask shape only inside it. Implement
            // by clipping the Canvas2D state to the bbox rectangle
            // before applying `destination-in`; outside the clip,
            // the element remains untouched.
            let (bx, by, bw, bh) = mask.subtree.bounds();
            if bw > 0.0 && bh > 0.0 {
                off_ctx.save();
                off_ctx.begin_path();
                off_ctx.rect(bx, by, bw, bh);
                off_ctx.clip();
                off_ctx.set_global_composite_operation("destination-in").ok();
                draw_element(&off_ctx, &mask.subtree, ancestor_vis, precision);
                off_ctx.set_global_composite_operation("source-over").ok();
                off_ctx.restore();
            }
            // Empty-bbox mask: no clip region; the element
            // body passes through unmodified (mask has nothing to
            // composite against).
        }
    }
    off_ctx.restore();

    // Copy the composited offscreen pixels onto the main ctx at
    // device coordinates (0, 0). The main ctx's alpha / blend_mode
    // will apply to the final blit, matching the non-mask path.
    ctx.save();
    ctx.set_transform(1.0, 0.0, 0.0, 1.0, 0.0, 0.0).ok();
    ctx.set_global_alpha(elem.opacity());
    ctx.set_global_composite_operation(blend_mode_css(elem.mode())).ok();
    ctx.draw_image_with_html_canvas_element(&off_canvas, 0.0, 0.0).ok();
    ctx.restore();
}

// ---------------------------------------------------------------------------
// Element body (non-mask path)
// ---------------------------------------------------------------------------

/// Render an element's geometry (fill / stroke / children) without
/// consulting ``common.mask``. Split from [draw_element] so the
/// mask path can invoke the body directly without recursing through
/// the mask dispatch.
fn draw_element_body(
    ctx: &CanvasRenderingContext2d,
    elem: &Element,
    ancestor_vis: Visibility,
    precision: f64,
) {
    // Effective visibility is the minimum of the inherited (capping)
    // visibility and this element's own. Groups/Layers propagate the
    // cap down to their children; Invisible stops the recursion.
    let effective = std::cmp::min(ancestor_vis, elem.visibility());
    if effective == Visibility::Invisible {
        return;
    }
    let outline = effective == Visibility::Outline;

    // Capture the inherited alpha BEFORE save(); save+set replaces
    // it, but we want this element's effective alpha to MULTIPLY into
    // any outer alpha (parent group opacity, isolation dim) rather
    // than replace it. ctx.save() saves the current alpha; ctx.restore()
    // pops it back when this element finishes.
    let parent_alpha = ctx.global_alpha();
    ctx.save();
    apply_transform(ctx, elem.transform());
    let base_alpha = parent_alpha * elem.opacity();
    ctx.set_global_alpha(base_alpha);
    ctx.set_global_composite_operation(blend_mode_css(elem.mode())).ok();

    match elem {
        Element::Line(e) => {
            let (mut stroke_op, mut stroke_align) = (1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                (stroke_op, stroke_align) = apply_stroke(ctx, e.stroke.as_ref());
            }
            // Shorten line endpoints to accommodate arrowheads
            let (mut lx1, mut ly1, mut lx2, mut ly2) = (e.x1, e.y1, e.x2, e.y2);
            if !outline {
                if let Some(s) = e.stroke.as_ref() {
                    let dx = lx2 - lx1;
                    let dy = ly2 - ly1;
                    let len = (dx * dx + dy * dy).sqrt();
                    if len > 0.0 {
                        let ux = dx / len;
                        let uy = dy / len;
                        let start_sb = super::arrowheads::arrow_setback(
                            s.start_arrow.as_str(), s.width, s.start_arrow_scale);
                        let end_sb = super::arrowheads::arrow_setback(
                            s.end_arrow.as_str(), s.width, s.end_arrow_scale);
                        lx1 += ux * start_sb;
                        ly1 += uy * start_sb;
                        lx2 -= ux * end_sb;
                        ly2 -= uy * end_sb;
                    }
                }
            }
            ctx.set_global_alpha(base_alpha * stroke_op);
            if !outline && !e.width_points.is_empty() {
                // Variable-width stroke via offset paths
                if let Some(s) = e.stroke.as_ref() {
                    let color = css_color(&s.color);
                    crate::algorithms::offset_path::render_variable_width_line(
                        ctx, lx1, ly1, lx2, ly2,
                        &e.width_points, &color, s.linecap,
                    );
                }
            } else {
                ctx.begin_path();
                ctx.move_to(lx1, ly1);
                ctx.line_to(lx2, ly2);
                stroke_aligned(ctx, stroke_align);
            }
            // Arrowheads
            if !outline {
                if let Some(s) = e.stroke.as_ref() {
                    let color = css_color(&s.color);
                    let center = s.arrow_align == ArrowAlign::CenterAtEnd;
                    super::arrowheads::draw_arrowheads_line(
                        ctx, e.x1, e.y1, e.x2, e.y2,
                        s.start_arrow.as_str(), s.end_arrow.as_str(),
                        s.start_arrow_scale, s.end_arrow_scale,
                        s.width, &color, center,
                    );
                }
            }
        }
        Element::Rect(e) => {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                let bbox = (e.x, e.y, e.width, e.height);
                fill_op = apply_fill(ctx, e.fill.as_ref(),
                    e.fill_gradient.as_deref(), bbox);
                (stroke_op, stroke_align) = apply_stroke_with_gradient(
                    ctx, e.stroke.as_ref(),
                    e.stroke_gradient.as_deref(), bbox);
            }
            let has_fill = !outline && (e.fill.is_some() || e.fill_gradient.is_some());
            let has_stroke = outline || e.stroke.is_some();
            if e.rx > 0.0 || e.ry > 0.0 {
                let rx = e.rx.max(0.0).min(e.width / 2.0);
                let ry = e.ry.max(0.0).min(e.height / 2.0);
                let x = e.x;
                let y = e.y;
                let w = e.width;
                let h = e.height;
                ctx.begin_path();
                ctx.move_to(x + rx, y);
                ctx.line_to(x + w - rx, y);
                ctx.quadratic_curve_to(x + w, y, x + w, y + ry);
                ctx.line_to(x + w, y + h - ry);
                ctx.quadratic_curve_to(x + w, y + h, x + w - rx, y + h);
                ctx.line_to(x + rx, y + h);
                ctx.quadratic_curve_to(x, y + h, x, y + h - ry);
                ctx.line_to(x, y + ry);
                ctx.quadratic_curve_to(x, y, x + rx, y);
                ctx.close_path();
                if has_fill {
                    ctx.set_global_alpha(base_alpha * fill_op);
                    ctx.fill();
                }
                if has_stroke {
                    ctx.set_global_alpha(base_alpha * stroke_op);
                    stroke_aligned(ctx, stroke_align);
                }
            } else {
                if has_fill {
                    ctx.set_global_alpha(base_alpha * fill_op);
                    ctx.fill_rect(e.x, e.y, e.width, e.height);
                }
                if has_stroke {
                    ctx.set_global_alpha(base_alpha * stroke_op);
                    let dasher_active = e.stroke.as_ref()
                        .map(|s| s.dash_align_anchors && !s.dash_array().is_empty())
                        .unwrap_or(false);
                    if dasher_active {
                        let s = e.stroke.as_ref().unwrap();
                        let cmds = vec![
                            PathCommand::MoveTo { x: e.x, y: e.y },
                            PathCommand::LineTo { x: e.x + e.width, y: e.y },
                            PathCommand::LineTo { x: e.x + e.width, y: e.y + e.height },
                            PathCommand::LineTo { x: e.x, y: e.y + e.height },
                            PathCommand::ClosePath,
                        ];
                        let expanded = crate::algorithms::dash_renderer::expand_dashed_stroke(
                            &cmds, s.dash_array(), true);
                        for sub in &expanded {
                            ctx.begin_path();
                            build_path(ctx, sub);
                            stroke_aligned(ctx, stroke_align);
                        }
                    } else {
                        // Use path-based stroke for alignment support
                        ctx.begin_path();
                        ctx.rect(e.x, e.y, e.width, e.height);
                        stroke_aligned(ctx, stroke_align);
                    }
                }
            }
        }
        Element::Circle(e) => {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                let bbox = (e.cx - e.r, e.cy - e.r, e.r * 2.0, e.r * 2.0);
                fill_op = apply_fill(ctx, e.fill.as_ref(),
                    e.fill_gradient.as_deref(), bbox);
                (stroke_op, stroke_align) = apply_stroke_with_gradient(
                    ctx, e.stroke.as_ref(),
                    e.stroke_gradient.as_deref(), bbox);
            }
            ctx.begin_path();
            ctx.arc(e.cx, e.cy, e.r, 0.0, std::f64::consts::TAU).ok();
            if !outline && (e.fill.is_some() || e.fill_gradient.is_some()) {
                ctx.set_global_alpha(base_alpha * fill_op);
                ctx.fill();
            }
            if outline || e.stroke.is_some() {
                ctx.set_global_alpha(base_alpha * stroke_op);
                stroke_aligned(ctx, stroke_align);
            }
        }
        Element::Ellipse(e) => {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                let bbox = (e.cx - e.rx, e.cy - e.ry, e.rx * 2.0, e.ry * 2.0);
                fill_op = apply_fill(ctx, e.fill.as_ref(),
                    e.fill_gradient.as_deref(), bbox);
                (stroke_op, stroke_align) = apply_stroke_with_gradient(
                    ctx, e.stroke.as_ref(),
                    e.stroke_gradient.as_deref(), bbox);
            }
            ctx.begin_path();
            ctx.ellipse(e.cx, e.cy, e.rx, e.ry, 0.0, 0.0, std::f64::consts::TAU)
                .ok();
            if !outline && (e.fill.is_some() || e.fill_gradient.is_some()) {
                ctx.set_global_alpha(base_alpha * fill_op);
                ctx.fill();
            }
            if outline || e.stroke.is_some() {
                ctx.set_global_alpha(base_alpha * stroke_op);
                stroke_aligned(ctx, stroke_align);
            }
        }
        Element::Polyline(e) => {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                let bbox = poly_bbox(&e.points);
                fill_op = apply_fill(ctx, e.fill.as_ref(),
                    e.fill_gradient.as_deref(), bbox);
                (stroke_op, stroke_align) = apply_stroke_with_gradient(
                    ctx, e.stroke.as_ref(),
                    e.stroke_gradient.as_deref(), bbox);
            }
            if !e.points.is_empty() {
                ctx.begin_path();
                ctx.move_to(e.points[0].0, e.points[0].1);
                for &(x, y) in &e.points[1..] {
                    ctx.line_to(x, y);
                }
                if !outline && (e.fill.is_some() || e.fill_gradient.is_some()) {
                    ctx.set_global_alpha(base_alpha * fill_op);
                    ctx.fill();
                }
                if outline || e.stroke.is_some() {
                    ctx.set_global_alpha(base_alpha * stroke_op);
                    stroke_aligned(ctx, stroke_align);
                }
            }
        }
        Element::Polygon(e) => {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                let bbox = poly_bbox(&e.points);
                fill_op = apply_fill(ctx, e.fill.as_ref(),
                    e.fill_gradient.as_deref(), bbox);
                (stroke_op, stroke_align) = apply_stroke_with_gradient(
                    ctx, e.stroke.as_ref(),
                    e.stroke_gradient.as_deref(), bbox);
            }
            if !e.points.is_empty() {
                ctx.begin_path();
                ctx.move_to(e.points[0].0, e.points[0].1);
                for &(x, y) in &e.points[1..] {
                    ctx.line_to(x, y);
                }
                ctx.close_path();
                if !outline && (e.fill.is_some() || e.fill_gradient.is_some()) {
                    ctx.set_global_alpha(base_alpha * fill_op);
                    ctx.fill();
                }
                if outline || e.stroke.is_some() {
                    ctx.set_global_alpha(base_alpha * stroke_op);
                    stroke_aligned(ctx, stroke_align);
                }
            }
        }
        Element::Path(e) => {
            let (mut fill_op, mut stroke_op, mut stroke_align) = (1.0, 1.0, StrokeAlign::Center);
            if outline {
                apply_outline_style(ctx);
            } else {
                let b = elem.bounds();
                fill_op = apply_fill(ctx, e.fill.as_ref(),
                    e.fill_gradient.as_deref(), b);
                (stroke_op, stroke_align) = apply_stroke_with_gradient(
                    ctx, e.stroke.as_ref(),
                    e.stroke_gradient.as_deref(), b);
            }
            // Fill uses the original path
            if !outline && (e.fill.is_some() || e.fill_gradient.is_some()) {
                ctx.begin_path();
                build_path(ctx, &e.d);
                ctx.set_global_alpha(base_alpha * fill_op);
                ctx.fill();
            }
            // Brushed stroke — when stroke_brush resolves to a known
            // Calligraphic brush, draw its variable-width outline as a
            // filled polygon using the element's stroke colour. Skips
            // the native stroke / arrowhead pipeline below. See
            // BRUSHES.md §Stroke styling interaction.
            if !outline && e.stroke_brush.is_some() {
                ctx.set_global_alpha(base_alpha * stroke_op);
                if draw_brushed_path(ctx, e, outline) {
                    // Handled; skip native stroke + arrowheads for this
                    // path (the brush renderer owns the entire stroke
                    // appearance).
                    return;
                }
                // Fall through to native stroke when the slug didn't
                // resolve or the brush type isn't supported yet.
            }
            // Stroke uses a shortened path to accommodate arrowheads
            if outline || e.stroke.is_some() {
                let shortened = if !outline {
                    if let Some(s) = e.stroke.as_ref() {
                        let start_sb = super::arrowheads::arrow_setback(
                            s.start_arrow.as_str(), s.width, s.start_arrow_scale);
                        let end_sb = super::arrowheads::arrow_setback(
                            s.end_arrow.as_str(), s.width, s.end_arrow_scale);
                        if start_sb > 0.0 || end_sb > 0.0 {
                            Some(super::arrowheads::shorten_path(&e.d, start_sb, end_sb))
                        } else { None }
                    } else { None }
                } else { None };
                let stroke_cmds = shortened.as_deref().unwrap_or(&e.d);
                ctx.set_global_alpha(base_alpha * stroke_op);
                if !outline && !e.width_points.is_empty() {
                    // Variable-width stroke via offset paths
                    if let Some(s) = e.stroke.as_ref() {
                        let color = css_color(&s.color);
                        crate::algorithms::offset_path::render_variable_width_path(
                            ctx, stroke_cmds, &e.width_points, &color, s.linecap,
                        );
                    }
                } else if let Some(s) = e.stroke.as_ref() {
                    if s.dash_align_anchors && !s.dash_array().is_empty() {
                        // Anchor-aligned dashing: expand into solid
                        // sub-paths and stroke each. apply_stroke
                        // already cleared the platform's dash array.
                        let expanded = crate::algorithms::dash_renderer::expand_dashed_stroke(
                            stroke_cmds, s.dash_array(), true);
                        for sub in &expanded {
                            ctx.begin_path();
                            build_path(ctx, sub);
                            stroke_aligned(ctx, stroke_align);
                        }
                    } else {
                        ctx.begin_path();
                        build_path(ctx, stroke_cmds);
                        stroke_aligned(ctx, stroke_align);
                    }
                } else {
                    ctx.begin_path();
                    build_path(ctx, stroke_cmds);
                    stroke_aligned(ctx, stroke_align);
                }
            }
            // Arrowheads
            if !outline {
                if let Some(s) = e.stroke.as_ref() {
                    let color = css_color(&s.color);
                    let center = s.arrow_align == ArrowAlign::CenterAtEnd;
                    super::arrowheads::draw_arrowheads(
                        ctx, &e.d,
                        s.start_arrow.as_str(), s.end_arrow.as_str(),
                        s.start_arrow_scale, s.end_arrow_scale,
                        s.width, &color, center,
                    );
                }
            }
        }
        Element::Text(e) => {
            let fill_op = apply_fill(ctx, e.fill.as_ref(), None, (0.0, 0.0, 0.0, 0.0));
            ctx.set_global_alpha(base_alpha * fill_op);
            // Multi-tspan text renders each tspan with its own
            // effective font (family / size / weight / style) and
            // text-decoration on a shared baseline. Single no-override
            // tspan falls through to the flat fast path below. First
            // pass covers the visible subset — font + decoration
            // overrides per tspan; per-tspan baseline-shift / rotate /
            // transform / dx / wrapping come in follow-ups.
            let is_flat = e.tspans.len() == 1 && e.tspans[0].has_no_overrides();
            if !is_flat {
                draw_segmented_text(ctx, e);
            } else {
            // Baseline-shift: super/sub render at a smaller size and
            // offset from the baseline.
            let (size_scale, y_shift) = match e.baseline_shift.as_str() {
                "super" => (0.7, -e.font_size * 0.35),
                "sub"   => (0.7,  e.font_size * 0.2),
                // Numeric "Npt" — shift up by N points, keep size.
                other => crate::workspace::app_state::parse_pt(other)
                    .map(|pt| (1.0_f64, -pt))
                    .unwrap_or((1.0, 0.0)),
            };
            let effective_fs = e.font_size * size_scale;
            let font = format!("{} {} {}px {}", e.font_style, e.font_weight, effective_fs, e.font_family);
            ctx.set_font(&font);
            // Letter-spacing = tracking + kerning (Canvas 2D has no
            // per-pair kerning, so numeric kerning adds to the
            // uniform letter-spacing advance — same cheap
            // approximation both fields use.)
            let ls_em = if !e.letter_spacing.is_empty() {
                crate::workspace::app_state::parse_em_as_thousandths(&e.letter_spacing)
                    .unwrap_or(0.0)
            } else { 0.0 };
            let kern_em = if !e.kerning.is_empty() {
                crate::workspace::app_state::parse_em_as_thousandths(&e.kerning)
                    .unwrap_or(0.0)
            } else { 0.0 };
            let ls_px = (ls_em + kern_em) * effective_fs / 1000.0;
            if ls_px != 0.0 {
                let _ = js_sys::Reflect::set(
                    ctx,
                    &js_sys::JsString::from("letterSpacing"),
                    &js_sys::JsString::from(format!("{}px", ls_px).as_str()),
                );
            }
            // V/H scale wraps the whole text draw. Character rotation
            // is *per-glyph* (matches SVG's <text rotate="N"> spec and
            // Illustrator's Character Rotation field): each glyph
            // rotates around its own baseline position, leaving the
            // overall layout on a horizontal baseline.
            let h_scale = if e.horizontal_scale.is_empty() { 1.0 }
                else { e.horizontal_scale.parse::<f64>().unwrap_or(100.0) / 100.0 };
            let v_scale = if e.vertical_scale.is_empty() { 1.0 }
                else { e.vertical_scale.parse::<f64>().unwrap_or(100.0) / 100.0 };
            let rotate_deg = if e.rotate.is_empty() { 0.0 }
                else { e.rotate.parse::<f64>().unwrap_or(0.0) };
            let rotate_rad = rotate_deg.to_radians();
            let needs_scale = h_scale != 1.0 || v_scale != 1.0;
            if needs_scale {
                ctx.save();
                ctx.translate(e.x, e.y).ok();
                ctx.scale(h_scale, v_scale).ok();
                ctx.translate(-e.x, -e.y).ok();
            }
            let measure = crate::tools::text_measure::make_measurer(&font, effective_fs);
            let max_w = if e.is_area_text() { e.width } else { 0.0 };
            // text-transform / font-variant: small-caps is rendered as
            // uppercase-with-same-size for now (close-enough placeholder
            // until OpenType small-caps substitution lands).
            let raw = e.content();
            let content_str = if e.text_transform == "uppercase"
                || e.font_variant == "small-caps"
            {
                raw.to_uppercase()
            } else if e.text_transform == "lowercase" {
                raw.to_lowercase()
            } else {
                raw
            };
            // Leading: line_height in pt (empty = Auto = font_size).
            // The text_layout::layout function uses its font_size
            // argument as the line height, so pass the leading value
            // there when set. Kept equal to font_size for Auto.
            //
            // Phase 8: when line_height is empty (Character Auto) and
            // the first paragraph wrapper carries jas:auto-leading,
            // override the Auto default with `auto_leading%` of the
            // font size. Per-paragraph leading would need text_layout
            // to take per-segment font_size; V1 applies one Auto
            // override element-wide using the first wrapper's value.
            let leading_px = if e.line_height.is_empty() {
                let auto_leading_pct = e.tspans.iter()
                    .find(|t| t.jas_role.as_deref() == Some("paragraph"))
                    .and_then(|t| t.jas_auto_leading);
                match auto_leading_pct {
                    Some(pct) => effective_fs * pct / 100.0,
                    None => effective_fs,  // pre-existing: Auto = 100%
                }
            } else {
                crate::workspace::app_state::parse_pt(&e.line_height).unwrap_or(effective_fs)
            };
            // Phase 5: build paragraph segments from the wrapper
            // tspans (jas_role == "paragraph"). The wrapper's
            // [left/right/first-line] indent and [space-before/after]
            // attributes are pt — convert to px (1pt == 1px in the
            // canvas coordinate space we use). Alignment maps the
            // §Alignment sub-mapping per area / point text.
            let segments = crate::algorithms::text_layout_paragraph::
                build_segments_from_text(&e.tspans, &content_str, e.is_area_text());
            let layout = crate::algorithms::text_layout::layout_with_paragraphs(
                &content_str,
                max_w,
                leading_px,
                &segments,
                measure.as_ref(),
            );
            let chars: Vec<char> = content_str.chars().collect();
            let has_underline = e.text_decoration.split_whitespace().any(|t| t == "underline");
            let has_strike = e.text_decoration.split_whitespace().any(|t| t == "line-through");
            for line in &layout.lines {
                let s: String = chars[line.start..line.end].iter().collect();
                let s = s.trim_end_matches('\n');
                let baseline = e.y + line.baseline_y + y_shift;
                // Per-line x shift comes from the first glyph's x,
                // which the paragraph-aware layout already shifted
                // by left_indent + first_line_indent + alignment.
                let line_x_shift = layout.glyphs
                    .get(line.glyph_start)
                    .map(|g| g.x)
                    .unwrap_or(0.0);
                let line_x = e.x + line_x_shift;
                if rotate_rad == 0.0 {
                    // Fast path: single fill_text per line. The CSS
                    // letterSpacing property set earlier handles the
                    // inter-glyph advance.
                    ctx.fill_text(s, line_x, baseline).ok();
                } else {
                    // Per-glyph rotation: each glyph rotates around
                    // its own (cx, baseline). fill_text takes only a
                    // whole string, so draw one char at a time and
                    // advance cx manually. letter_spacing is folded
                    // into the advance the same way the fast path
                    // relies on CSS letterSpacing.
                    let mut cx = line_x;
                    for ch in s.chars() {
                        let ch_str = ch.to_string();
                        ctx.save();
                        ctx.translate(cx, baseline).ok();
                        ctx.rotate(rotate_rad).ok();
                        ctx.fill_text(&ch_str, 0.0, 0.0).ok();
                        ctx.restore();
                        cx += measure(&ch_str) + ls_px;
                    }
                }
                if has_underline || has_strike {
                    let w = measure(s);
                    draw_text_decorations(
                        ctx, line_x, baseline, w, effective_fs,
                        has_underline, has_strike, e.fill.as_ref(),
                    );
                }
            }
            // Phase 6: list markers. Walk the segments and draw each
            // active list paragraph's marker glyph at x = element.x +
            // segment.left_indent, baseline = first-line baseline.
            // Counter values are computed once across all segments so
            // the run rule (consecutive same-style num-* paragraphs
            // count up; anything else resets) holds across the
            // element's whole content.
            if !segments.is_empty() {
                let counters = crate::algorithms::text_layout_paragraph::
                    compute_counters(&segments);
                for (si, seg) in segments.iter().enumerate() {
                    let style = match &seg.list_style {
                        Some(s) if !s.is_empty() => s,
                        _ => continue,
                    };
                    let marker = crate::algorithms::text_layout_paragraph::
                        marker_text(style, counters[si]);
                    if marker.is_empty() { continue; }
                    // First-line baseline: find the first layout line
                    // that starts at or after this segment's char range.
                    let first_line = layout.lines.iter()
                        .find(|l| l.start >= seg.char_start);
                    let baseline = match first_line {
                        Some(l) => e.y + l.baseline_y + y_shift,
                        None => continue,
                    };
                    let marker_x = e.x + seg.left_indent;
                    ctx.fill_text(&marker, marker_x, baseline).ok();
                }
            }
            // Reset letterSpacing so subsequent text elements without
            // the attribute draw without inheriting this one's value.
            if ls_px != 0.0 {
                let _ = js_sys::Reflect::set(
                    ctx,
                    &js_sys::JsString::from("letterSpacing"),
                    &js_sys::JsString::from("0px"),
                );
            }
            if needs_scale {
                ctx.restore();
            }
            } // end else (is_flat)
        }
        Element::TextPath(e) => {
            // Draw the path as a faint guide line
            ctx.set_stroke_style_str("rgba(180,180,180,0.4)");
            ctx.set_line_width(1.0);
            ctx.begin_path();
            build_path(ctx, &e.d);
            ctx.stroke();

            // Draw text along the path
            let content_str = e.content();
            if !content_str.is_empty() && !e.d.is_empty() {
                let fill_op = apply_fill(ctx, e.fill.as_ref(), None, (0.0, 0.0, 0.0, 0.0));
                ctx.set_global_alpha(base_alpha * fill_op);
                let font = format!(
                    "{} {} {}px {}",
                    e.font_style, e.font_weight, e.font_size, e.font_family
                );
                ctx.set_font(&font);

                // Flatten the path and measure total length
                let pts = flatten_path_commands(&e.d);
                let mut lengths = vec![0.0_f64];
                for i in 1..pts.len() {
                    let dx = pts[i].0 - pts[i - 1].0;
                    let dy = pts[i].1 - pts[i - 1].1;
                    lengths.push(lengths[i - 1] + (dx * dx + dy * dy).sqrt());
                }
                let total = *lengths.last().unwrap_or(&0.0);
                if total > 0.0 {
                    let mut offset = e.start_offset * total;
                    for ch in content_str.chars() {
                        let ch_str = ch.to_string();
                        let ch_width = ctx.measure_text(&ch_str).map(|m: web_sys::TextMetrics| m.width()).unwrap_or(8.0);
                        let t = (offset + ch_width / 2.0) / total;
                        if t > 1.0 { break; }
                        if t >= 0.0 {
                            // Get point and tangent at offset
                            let (px, py) = path_point_at_offset(&e.d, t);
                            let t2 = ((offset + ch_width) / total).min(1.0);
                            let (px2, py2) = path_point_at_offset(&e.d, t2);
                            let angle = (py2 - py).atan2(px2 - px);

                            ctx.save();
                            ctx.translate(px, py).ok();
                            ctx.rotate(angle).ok();
                            ctx.fill_text(&ch_str, -ch_width / 2.0, e.font_size * 0.35).ok();
                            ctx.restore();
                        }
                        offset += ch_width;
                    }
                }
            }
        }
        Element::Group(g) => {
            // Cap each child's effective visibility by our own
            // effective visibility (which already incorporates our
            // ancestor's cap).
            for child in &g.children {
                draw_element(ctx, child, effective, precision);
            }
        }
        Element::Layer(l) => {
            for child in &l.children {
                draw_element(ctx, child, effective, precision);
            }
        }
        Element::Live(v) => {
            match v {
                crate::geometry::live::LiveVariant::CompoundShape(cs) => {
                    let ps = cs.evaluate(precision);
                    let (mut fill_op, mut stroke_op, mut stroke_align) =
                        (1.0, 1.0, StrokeAlign::Center);
                    if outline {
                        apply_outline_style(ctx);
                    } else {
                        fill_op = apply_fill(ctx, cs.fill.as_ref(), None, (0.0, 0.0, 0.0, 0.0));
                        (stroke_op, stroke_align) =
                            apply_stroke(ctx, cs.stroke.as_ref());
                    }
                    if ps.iter().any(|r| r.len() >= 2) {
                        ctx.begin_path();
                        for ring in &ps {
                            if ring.len() < 2 { continue; }
                            ctx.move_to(ring[0].0, ring[0].1);
                            for &(x, y) in &ring[1..] {
                                ctx.line_to(x, y);
                            }
                            ctx.close_path();
                        }
                        if !outline && cs.fill.is_some() {
                            ctx.set_global_alpha(base_alpha * fill_op);
                            ctx.fill();
                        }
                        if outline || cs.stroke.is_some() {
                            ctx.set_global_alpha(base_alpha * stroke_op);
                            stroke_aligned(ctx, stroke_align);
                        }
                    }
                }
            }
        }
    }
    ctx.restore();
}

// ---------------------------------------------------------------------------
// Draw selection overlays
// ---------------------------------------------------------------------------

/// Trace the given element's geometry as a sub-path on `ctx` without
/// filling or stroking. Used by `draw_selection_overlays` to stroke
/// Draw the underline and/or strikethrough lines for a text run.
/// Called from Text rendering when `text_decoration` includes either
/// token. Positions follow CSS-ish conventions: underline sits at
/// ~5% of the font size below the baseline, strike-through at roughly
/// the x-height (about 35% above the baseline). Line thickness is a
/// fixed fraction of the font size so it scales with the text.
/// Draw a Text element's tspans in sequence on a shared baseline,
/// each using its effective font (override || parent-element fallback)
/// and its effective text-decoration. Wraps the minimum subset of
/// TSPAN.md's "Rendering" section: different fonts and decorations
/// across spans in the same Text. Omits per-tspan baseline-shift,
/// transform, rotate, dx, small-caps, and multi-line wrapping —
/// those still collapse to the element-wide defaults for now.
fn draw_segmented_text(
    ctx: &CanvasRenderingContext2d,
    e: &crate::geometry::element::TextElem,
) {
    // Parent fallbacks for each tspan field.
    let parent_bold = e.font_weight == "bold";
    let parent_italic = e.font_style == "italic" || e.font_style == "oblique";
    // Parent decoration tokens — used when the tspan doesn't override.
    let parent_decor: Vec<&str> = e.text_decoration
        .split_whitespace()
        .filter(|t| !t.is_empty() && *t != "none")
        .collect();

    // The baseline sits at the first visual line: element y + 0.8 *
    // font_size. Segmented rendering is one-line only for now.
    let baseline = e.y + e.font_size * 0.8;
    let mut cx = e.x;

    for t in &e.tspans {
        if t.content.is_empty() {
            continue;
        }
        let eff_family = t.font_family.as_deref().unwrap_or(&e.font_family);
        let eff_size = t.font_size.unwrap_or(e.font_size);
        let eff_weight = match t.font_weight.as_deref() {
            Some(w) => w,
            None => if parent_bold { "bold" } else { "normal" },
        };
        let eff_style = match t.font_style.as_deref() {
            Some(s) => s,
            None => if parent_italic { "italic" } else { "normal" },
        };
        let font = format!("{} {} {}px {}",
            eff_style, eff_weight, eff_size, eff_family);
        ctx.set_font(&font);

        // Per-tspan positioning: dx is a leading-edge horizontal
        // nudge in em (so a fresh tspan advance contribution);
        // baseline_shift in pt offsets the baseline (sign convention
        // mirrors CSS / TSPAN.md: + is up — negative y in canvas).
        // rotate / transform wrap the tspan draw around its starting
        // baseline position. All compose on top of the shared
        // baseline from the parent Text.
        let dx_px = t.dx.unwrap_or(0.0) * eff_size;
        cx += dx_px;
        let baseline_shift = t.baseline_shift.unwrap_or(0.0);
        let tspan_baseline = baseline - baseline_shift;
        let rotate_deg = t.rotate.unwrap_or(0.0);
        let rotate_rad = rotate_deg.to_radians();
        let has_transform = t.transform.is_some();
        let has_rotate = rotate_rad != 0.0;

        if has_rotate || has_transform {
            ctx.save();
            ctx.translate(cx, tspan_baseline).ok();
            if let Some(tr) = &t.transform {
                ctx.transform(tr.a, tr.b, tr.c, tr.d, tr.e, tr.f).ok();
            }
            if has_rotate {
                ctx.rotate(rotate_rad).ok();
            }
            ctx.fill_text(&t.content, 0.0, 0.0).ok();
        } else {
            ctx.fill_text(&t.content, cx, tspan_baseline).ok();
        }

        // Effective decoration: Some([..]) overrides parent (empty
        // list = explicit no-decoration); None inherits parent tokens.
        let (has_underline, has_strike) = match t.text_decoration.as_deref() {
            Some(members) => (
                members.iter().any(|m| m == "underline"),
                members.iter().any(|m| m == "line-through"),
            ),
            None => (
                parent_decor.iter().any(|m| *m == "underline"),
                parent_decor.iter().any(|m| *m == "line-through"),
            ),
        };
        let measure = crate::tools::text_measure::make_measurer(&font, eff_size);
        let w = measure(&t.content);
        if has_underline || has_strike {
            if has_rotate || has_transform {
                // Decorations draw in the tspan's local frame so
                // they rotate / transform with the glyphs.
                draw_text_decorations(
                    ctx, 0.0, 0.0, w, eff_size,
                    has_underline, has_strike, e.fill.as_ref(),
                );
            } else {
                draw_text_decorations(
                    ctx, cx, tspan_baseline, w, eff_size,
                    has_underline, has_strike, e.fill.as_ref(),
                );
            }
        }
        if has_rotate || has_transform {
            ctx.restore();
        }
        cx += w;
    }
}

fn draw_text_decorations(
    ctx: &CanvasRenderingContext2d,
    x: f64,
    baseline_y: f64,
    width: f64,
    font_size: f64,
    underline: bool,
    strike: bool,
    fill: Option<&Fill>,
) {
    let color = match fill {
        Some(f) => css_color(&f.color),
        None => "currentColor".to_string(),
    };
    let thickness = (font_size * 0.07).max(1.0);
    ctx.set_stroke_style_str(&color);
    ctx.set_line_width(thickness);
    if underline {
        let y = baseline_y + font_size * 0.12;
        ctx.begin_path();
        ctx.move_to(x, y);
        ctx.line_to(x + width, y);
        ctx.stroke();
    }
    if strike {
        let y = baseline_y - font_size * 0.3;
        ctx.begin_path();
        ctx.move_to(x, y);
        ctx.line_to(x + width, y);
        ctx.stroke();
    }
}

/// the element's path in the selection color.
///
/// Text, TextPath, Group, and Layer are not traced here — they use a
/// bounding-box overlay (Text/TextPath) or rely on their descendants'
/// individual highlights (Group/Layer).
fn trace_element_path(ctx: &CanvasRenderingContext2d, elem: &Element) {
    match elem {
        Element::Line(e) => {
            ctx.move_to(e.x1, e.y1);
            ctx.line_to(e.x2, e.y2);
        }
        Element::Rect(e) => {
            if e.rx > 0.0 || e.ry > 0.0 {
                let rx = e.rx.max(0.0).min(e.width / 2.0);
                let ry = e.ry.max(0.0).min(e.height / 2.0);
                let x = e.x;
                let y = e.y;
                let w = e.width;
                let h = e.height;
                ctx.move_to(x + rx, y);
                ctx.line_to(x + w - rx, y);
                ctx.quadratic_curve_to(x + w, y, x + w, y + ry);
                ctx.line_to(x + w, y + h - ry);
                ctx.quadratic_curve_to(x + w, y + h, x + w - rx, y + h);
                ctx.line_to(x + rx, y + h);
                ctx.quadratic_curve_to(x, y + h, x, y + h - ry);
                ctx.line_to(x, y + ry);
                ctx.quadratic_curve_to(x, y, x + rx, y);
                ctx.close_path();
            } else {
                ctx.rect(e.x, e.y, e.width, e.height);
            }
        }
        Element::Circle(e) => {
            ctx.move_to(e.cx + e.r, e.cy);
            ctx.arc(e.cx, e.cy, e.r, 0.0, std::f64::consts::TAU).ok();
        }
        Element::Ellipse(e) => {
            ctx.move_to(e.cx + e.rx, e.cy);
            ctx.ellipse(e.cx, e.cy, e.rx, e.ry, 0.0, 0.0, std::f64::consts::TAU)
                .ok();
        }
        Element::Polyline(e) => {
            if !e.points.is_empty() {
                ctx.move_to(e.points[0].0, e.points[0].1);
                for &(x, y) in &e.points[1..] {
                    ctx.line_to(x, y);
                }
            }
        }
        Element::Polygon(e) => {
            if !e.points.is_empty() {
                ctx.move_to(e.points[0].0, e.points[0].1);
                for &(x, y) in &e.points[1..] {
                    ctx.line_to(x, y);
                }
                ctx.close_path();
            }
        }
        Element::Path(e) => {
            build_path(ctx, &e.d);
        }
        Element::Text(_)
        | Element::TextPath(_)
        | Element::Group(_)
        | Element::Layer(_) => {
            // Handled separately via bounding-box overlays or
            // descendant highlights.
        }
        Element::Live(v) => match v {
            crate::geometry::live::LiveVariant::CompoundShape(cs) => {
                let ps = cs.evaluate(crate::geometry::live::DEFAULT_PRECISION);
                for ring in &ps {
                    if ring.len() < 2 { continue; }
                    ctx.move_to(ring[0].0, ring[0].1);
                    for &(x, y) in &ring[1..] {
                        ctx.line_to(x, y);
                    }
                    ctx.close_path();
                }
            }
        },
    }
}

fn draw_selection_overlays(ctx: &CanvasRenderingContext2d, doc: &Document) {
    let sel_color = "rgba(0, 120, 215, 0.9)";
    ctx.set_stroke_style_str(sel_color);
    ctx.set_line_width(1.0);

    for es in &doc.selection {
        let elem = match doc.get_element(&es.path) {
            Some(e) => e,
            None => continue,
        };

        // Text and TextPath get a bounding-box highlight instead of
        // a path trace. For area text the bbox aligns with the area
        // (that's what `bounds()` returns); for point text it wraps
        // the drawn glyphs; for TextPath it wraps the path the text
        // follows.
        let is_text_like = matches!(elem, Element::Text(_) | Element::TextPath(_));
        // Containers (Group / Layer) are picked as whole elements by
        // the Selection tool's hit_test (which stops at direct layer
        // children). Per Illustrator convention, a selected Group is
        // shown as a single bbox around its contents — not as
        // individual descendant outlines — so we render the
        // children-union bounds here.
        let is_container = matches!(elem, Element::Group(_) | Element::Layer(_));

        if is_text_like || is_container {
            let (bx, by, bw, bh) = elem.bounds();
            if bw > 0.0 && bh > 0.0 {
                ctx.stroke_rect(bx, by, bw, bh);
            }
        } else {
            // Stroke the element's own path in bright blue.
            ctx.begin_path();
            trace_element_path(ctx, elem);
            ctx.stroke();

            // Draw the control-point squares. A selected CP (per the
            // `Partial` set, or any CP when kind is `All`) gets the
            // solid blue fill; others get white. On `All`, every CP
            // is filled blue — the whole element is grabbable.
            let cps = control_points(elem);
            let half = HANDLE_DRAW_SIZE / 2.0;
            // Re-apply stroke color (stroke() above may leave it as-is
            // but be explicit for the rect strokes below).
            ctx.set_stroke_style_str(sel_color);
            for (i, &(px, py)) in cps.iter().enumerate() {
                if es.kind.contains(i) {
                    ctx.set_fill_style_str(sel_color);
                } else {
                    ctx.set_fill_style_str("white");
                }
                ctx.fill_rect(px - half, py - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE);
                ctx.stroke_rect(px - half, py - half, HANDLE_DRAW_SIZE, HANDLE_DRAW_SIZE);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Artboard rendering (ARTBOARDS.md §Canvas appearance)
// ---------------------------------------------------------------------------
//
// Z-order around the existing element / selection passes:
//
//   1. Canvas background (white fill in `render()`)
//   2. draw_artboard_fills       — per artboard, list order
//   3. (element tree — unchanged)
//   4. draw_fade_overlay         — dims off-artboard regions (phase-E)
//   5. draw_artboard_borders     — thin default borders
//   6. draw_artboard_accent      — 2px outline for panel-selected
//   7. draw_artboard_labels      — "N  Name" above top-left
//   8. draw_artboard_display_marks — center mark / cross hairs / safe areas
//   9. draw_selection_overlays   — unchanged
//
// Phase-D first pass: borders / accent / label / marks are drawn at
// 1 device-pixel at the current canvas transform — matching the
// existing selection-overlay idiom. Full zoom-independent screen-
// pixel sizing waits on passing the canvas scale through `render()`.

const ARTBOARD_BORDER_COLOR: &str = "rgb(48,48,48)";
const ARTBOARD_ACCENT_COLOR: &str = "rgba(0, 120, 215, 0.95)";
const ARTBOARD_MARK_COLOR: &str = "rgb(150,150,150)";
const ARTBOARD_LABEL_COLOR: &str = "rgb(200,200,200)";

fn artboard_fill_css(fill: &ArtboardFill) -> Option<String> {
    match fill {
        // Default-Transparent artboards visually appear white over
        // the gray pasteboard — matching the convention in every
        // vector-illustration app. A truly see-through artboard
        // isn't a real-world use case here.
        ArtboardFill::Transparent => Some("#ffffff".to_string()),
        ArtboardFill::Color(hex) => Some(hex.clone()),
    }
}

fn draw_artboard_fills(ctx: &CanvasRenderingContext2d, doc: &Document) {
    for ab in &doc.artboards {
        if let Some(css) = artboard_fill_css(&ab.fill) {
            ctx.set_fill_style_str(&css);
            ctx.fill_rect(ab.x, ab.y, ab.width, ab.height);
        }
        // Transparent: no fill, canvas shows through.
    }
}

/// Z-layer 4: fade overlay — ARTBOARDS.md §Canvas appearance.
///
/// When `doc.artboard_options.fade_region_outside_artboard` is on,
/// paints a 50%-opacity canvas-gray mask over every screen region
/// not inside any artboard. The effect dims elements that live
/// outside the printable areas.
///
/// Implementation: fill the entire canvas in the fade color, then
/// punch out each artboard via the `destination-out` composite
/// operation (which subtracts the filled rect from the mask).
/// Canvas state is saved and restored so the composite change
/// doesn't leak into later passes.
fn draw_fade_overlay(
    ctx: &CanvasRenderingContext2d,
    doc: &Document,
    width: f64,
    height: f64,
) {
    // Disabled while the pasteboard is theme-gray and artboards are
    // painted opaque white: this routine's destination-out punches
    // alpha=0 holes through the white artboard fills, leaving
    // canvas-DOM-bg gray inside the artboards. Reinstate when the
    // fade can target only the pasteboard region (e.g. via a
    // separate raster mask drawn before the artboard fill pass).
    let _ = (ctx, doc, width, height);
    return;
    #[allow(unreachable_code)]
    if !doc.artboard_options.fade_region_outside_artboard {
        return;
    }
    if doc.artboards.is_empty() {
        return;
    }
    ctx.save();
    // Fill the full canvas with 50% theme-gray.
    ctx.set_fill_style_str("rgba(160,160,160,0.5)");
    ctx.fill_rect(0.0, 0.0, width, height);
    // Punch out each artboard.
    ctx.set_global_composite_operation("destination-out").ok();
    ctx.set_fill_style_str("rgba(0,0,0,1)");
    for ab in &doc.artboards {
        ctx.fill_rect(ab.x, ab.y, ab.width, ab.height);
    }
    ctx.restore();
}

fn draw_artboard_borders(ctx: &CanvasRenderingContext2d, doc: &Document) {
    ctx.set_stroke_style_str(ARTBOARD_BORDER_COLOR);
    ctx.set_line_width(1.0);
    for ab in &doc.artboards {
        ctx.stroke_rect(ab.x, ab.y, ab.width, ab.height);
    }
}

fn draw_artboard_accent(
    ctx: &CanvasRenderingContext2d,
    doc: &Document,
    panel_selected: &[String],
) {
    if panel_selected.is_empty() {
        return;
    }
    ctx.set_stroke_style_str(ARTBOARD_ACCENT_COLOR);
    ctx.set_line_width(2.0);
    for ab in &doc.artboards {
        if panel_selected.iter().any(|id| id == &ab.id) {
            // 2px outside the 1px default: expand the rect by ~1.5
            // so the outer edge of the accent sits one pixel outside
            // the default border's outer edge.
            let pad = 1.5;
            ctx.stroke_rect(
                ab.x - pad,
                ab.y - pad,
                ab.width + 2.0 * pad,
                ab.height + 2.0 * pad,
            );
        }
    }
}

fn draw_artboard_labels(ctx: &CanvasRenderingContext2d, doc: &Document) {
    // Font set once; zoom-independent sizing deferred (see module-
    // level comment). At the current transform, 11px is the closest
    // equivalent to the theme's panel-row text.
    ctx.set_font("11px sans-serif");
    ctx.set_fill_style_str(ARTBOARD_LABEL_COLOR);
    ctx.set_text_baseline("bottom");
    ctx.set_text_align("left");
    for (i, ab) in doc.artboards.iter().enumerate() {
        let label = format!("{}  {}", i + 1, ab.name);
        // Label sits just above the top-left corner, offset a few
        // document units up.
        let _ = ctx.fill_text(&label, ab.x, ab.y - 3.0);
    }
}

fn draw_artboard_center_mark(ctx: &CanvasRenderingContext2d, ab: &Artboard) {
    let cx = ab.x + ab.width / 2.0;
    let cy = ab.y + ab.height / 2.0;
    let arm = 5.0;
    ctx.set_stroke_style_str(ARTBOARD_MARK_COLOR);
    ctx.set_line_width(1.0);
    ctx.begin_path();
    ctx.move_to(cx - arm, cy);
    ctx.line_to(cx + arm, cy);
    ctx.move_to(cx, cy - arm);
    ctx.line_to(cx, cy + arm);
    ctx.stroke();
}

fn draw_artboard_cross_hairs(ctx: &CanvasRenderingContext2d, ab: &Artboard) {
    let cx = ab.x + ab.width / 2.0;
    let cy = ab.y + ab.height / 2.0;
    ctx.set_stroke_style_str(ARTBOARD_MARK_COLOR);
    ctx.set_line_width(1.0);
    ctx.begin_path();
    ctx.move_to(ab.x, cy);
    ctx.line_to(ab.x + ab.width, cy);
    ctx.move_to(cx, ab.y);
    ctx.line_to(cx, ab.y + ab.height);
    ctx.stroke();
}

fn draw_artboard_safe_areas(ctx: &CanvasRenderingContext2d, ab: &Artboard) {
    // Action-safe at 90%, title-safe at 80%, centered.
    ctx.set_stroke_style_str(ARTBOARD_MARK_COLOR);
    ctx.set_line_width(1.0);
    for frac in [0.9_f64, 0.8_f64].iter() {
        let w = ab.width * frac;
        let h = ab.height * frac;
        let x = ab.x + (ab.width - w) / 2.0;
        let y = ab.y + (ab.height - h) / 2.0;
        ctx.stroke_rect(x, y, w, h);
    }
}

fn draw_artboard_display_marks(ctx: &CanvasRenderingContext2d, doc: &Document) {
    for ab in &doc.artboards {
        if ab.show_center_mark {
            draw_artboard_center_mark(ctx, ab);
        }
        if ab.show_cross_hairs {
            draw_artboard_cross_hairs(ctx, ab);
        }
        if ab.show_video_safe_areas {
            draw_artboard_safe_areas(ctx, ab);
        }
    }
}

// ---------------------------------------------------------------------------
// Public render function
// ---------------------------------------------------------------------------

/// Render the entire document to the canvas.
///
/// `precision` is the Boolean-panel Precision value used when
/// evaluating compound shapes. `panel_selected_artboards` is the
/// ordered list of artboard ids currently panel-selected (used for
/// the accent border at Z-layer 6); pass `&[]` when the Artboards
/// panel isn't wired (e.g., Rust Phase C not yet landed).
pub fn render(
    ctx: &CanvasRenderingContext2d,
    width: f64,
    height: f64,
    doc: &Document,
    precision: f64,
    panel_selected_artboards: &[String],
    mask_isolation_path: Option<&[usize]>,
    layers_isolation_path: Option<&[usize]>,
    brush_libraries: &serde_json::Value,
) {
    // Install the brush registry for this render. Dropped on exit
    // (guard restores the prior value), so nested renders nest safely.
    let _brush_guard = register_brush_libraries(brush_libraries.clone());

    // Layer 1 (canvas background) is now painted by the caller
    // (workspace::app_state::repaint) BEFORE applying the
    // view transform, so the background fills the viewport in
    // screen-space rather than the document rectangle. The
    // (width, height) parameters here are now informational only —
    // the renderer assumes the caller has cleared / filled the
    // viewport and applied the zoom + pan transform.
    let _ = (width, height);

    // Layer 2: artboard fills (list order, later wins in overlaps).
    draw_artboard_fills(ctx, doc);

    // Layer 3: document element tree. In mask-isolation mode
    // (OPACITY.md §Preview interactions), render only the mask
    // subtree of the isolated element — everything else on the
    // canvas is hidden until the user exits isolation.
    if let Some(path) = mask_isolation_path {
        if let Some(elem) = doc.get_element(&path.to_vec()) {
            if let Some(mask) = elem.common().mask.as_deref() {
                draw_element(ctx, &mask.subtree, Visibility::Preview, precision);
            }
        }
    } else if let Some(iso_path) = layers_isolation_path {
        // Layers-panel isolation visual (LYR-181):
        //   - Non-isolated elements render at low alpha (parent_alpha
        //     multiplies through draw_element_body).
        //   - Isolated subtree paints over them at full alpha.
        // Artboard fills (already painted above) stay full strength.
        ctx.save();
        ctx.set_global_alpha(0.15);
        for layer in &doc.layers {
            draw_element(ctx, layer, Visibility::Preview, precision);
        }
        ctx.restore();
        if let Some(iso_elem) = doc.get_element(&iso_path.to_vec()) {
            draw_element(ctx, iso_elem, Visibility::Preview, precision);
        }
    } else {
        for layer in &doc.layers {
            draw_element(ctx, layer, Visibility::Preview, precision);
        }
    }

    // Layer 4: fade overlay (dims regions outside any artboard).
    draw_fade_overlay(ctx, doc, width, height);

    // Layer 5: artboard borders (thin, above elements so they're
    // never occluded).
    draw_artboard_borders(ctx, doc);

    // Layer 6: accent borders for panel-selected artboards.
    draw_artboard_accent(ctx, doc, panel_selected_artboards);

    // Layer 7: artboard labels above top-left.
    draw_artboard_labels(ctx, doc);

    // Layer 8: per-artboard display marks.
    draw_artboard_display_marks(ctx, doc);

    // Layer 9: selection overlays — unchanged.
    draw_selection_overlays(ctx, doc);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn css_color_opaque_black() {
        let c = Color::Rgb { r: 0.0, g: 0.0, b: 0.0, a: 1.0 };
        assert_eq!(css_color(&c), "rgb(0,0,0)");
    }

    #[test]
    fn css_color_opaque_white() {
        let c = Color::Rgb { r: 1.0, g: 1.0, b: 1.0, a: 1.0 };
        assert_eq!(css_color(&c), "rgb(255,255,255)");
    }

    #[test]
    fn css_color_opaque_red() {
        let c = Color::Rgb { r: 1.0, g: 0.0, b: 0.0, a: 1.0 };
        assert_eq!(css_color(&c), "rgb(255,0,0)");
    }

    #[test]
    fn css_color_transparent() {
        let c = Color::Rgb { r: 1.0, g: 0.0, b: 0.0, a: 0.5 };
        assert_eq!(css_color(&c), "rgba(255,0,0,0.5)");
    }

    #[test]
    fn css_color_fully_transparent() {
        let c = Color::Rgb { r: 0.0, g: 0.0, b: 0.0, a: 0.0 };
        assert_eq!(css_color(&c), "rgba(0,0,0,0)");
    }

    #[test]
    fn css_color_mid_gray() {
        let c = Color::Rgb { r: 0.5, g: 0.5, b: 0.5, a: 1.0 };
        assert_eq!(css_color(&c), "rgb(127,127,127)");
    }

    // ── blend_mode_css ─────────────────────────────────────

    #[test]
    fn blend_mode_css_normal_is_source_over() {
        assert_eq!(blend_mode_css(BlendMode::Normal), "source-over");
    }

    #[test]
    fn blend_mode_css_maps_all_sixteen_variants() {
        // Every variant must map to a non-empty Canvas2D composite
        // operation name. Underscore variants in the Rust enum must
        // become hyphenated in CSS (color_burn → "color-burn").
        let pairs = [
            (BlendMode::Normal,      "source-over"),
            (BlendMode::Darken,      "darken"),
            (BlendMode::Multiply,    "multiply"),
            (BlendMode::ColorBurn,   "color-burn"),
            (BlendMode::Lighten,     "lighten"),
            (BlendMode::Screen,      "screen"),
            (BlendMode::ColorDodge,  "color-dodge"),
            (BlendMode::Overlay,     "overlay"),
            (BlendMode::SoftLight,   "soft-light"),
            (BlendMode::HardLight,   "hard-light"),
            (BlendMode::Difference,  "difference"),
            (BlendMode::Exclusion,   "exclusion"),
            (BlendMode::Hue,         "hue"),
            (BlendMode::Saturation,  "saturation"),
            (BlendMode::Color,       "color"),
            (BlendMode::Luminosity,  "luminosity"),
        ];
        assert_eq!(pairs.len(), 16);
        for (mode, expected) in pairs {
            assert_eq!(blend_mode_css(mode), expected,
                       "mapping mismatch for {:?}", mode);
        }
    }

    #[test]
    fn blend_mode_css_hyphenates_compound_names() {
        assert_eq!(blend_mode_css(BlendMode::ColorBurn), "color-burn");
        assert_eq!(blend_mode_css(BlendMode::ColorDodge), "color-dodge");
        assert_eq!(blend_mode_css(BlendMode::SoftLight), "soft-light");
        assert_eq!(blend_mode_css(BlendMode::HardLight), "hard-light");
    }

    // ── mask_plan (Track C) ────────────────────────────────

    fn test_mask(clip: bool, invert: bool, disabled: bool) -> Mask {
        Mask {
            subtree: Box::new(Element::Group(GroupElem::default())),
            clip,
            invert,
            disabled,
            linked: true,
            unlink_transform: None,
        }
    }

    #[test]
    fn mask_plan_clip_not_inverted_is_clip_in() {
        let m = test_mask(true, false, false);
        assert_eq!(mask_plan(&m), Some(MaskPlan::ClipIn));
    }

    #[test]
    fn mask_plan_clip_inverted_is_clip_out() {
        let m = test_mask(true, true, false);
        assert_eq!(mask_plan(&m), Some(MaskPlan::ClipOut));
    }

    #[test]
    fn mask_plan_disabled_is_none() {
        // disabled overrides both clip and invert: falls back to no
        // mask rendering per OPACITY.md §States.
        assert_eq!(mask_plan(&test_mask(true, false, true)), None);
        assert_eq!(mask_plan(&test_mask(true, true, true)), None);
        assert_eq!(mask_plan(&test_mask(false, false, true)), None);
        assert_eq!(mask_plan(&test_mask(false, true, true)), None);
    }

    #[test]
    fn mask_plan_no_clip_no_invert_is_reveal_outside_bbox() {
        // Phase 2: clip=false, invert=false keeps the element
        // visible outside the mask subtree's bounding box and
        // clips to the mask inside it.
        assert_eq!(
            mask_plan(&test_mask(false, false, false)),
            Some(MaskPlan::RevealOutsideBbox)
        );
    }

    #[test]
    fn mask_plan_no_clip_inverted_collapses_to_clip_out() {
        // Alpha-based mask: `clip: false, invert: true` gives the
        // same output as `clip: true, invert: true` because the
        // mask's outside-region alpha is zero either way. Phase 2
        // routes them through the same `ClipOut` path.
        assert_eq!(
            mask_plan(&test_mask(false, true, false)),
            Some(MaskPlan::ClipOut)
        );
    }

    // ── promote_bytes_to_luminance (PDF §11 soft-mask) ─────

    fn pixel(r: u8, g: u8, b: u8, a: u8) -> [u8; 4] { [r, g, b, a] }

    #[test]
    fn luminance_white_opaque_keeps_alpha() {
        let mut bytes = pixel(255, 255, 255, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert_eq!(bytes[3], 255);
    }

    #[test]
    fn luminance_black_opaque_drops_to_zero() {
        let mut bytes = pixel(0, 0, 0, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert_eq!(bytes[3], 0);
    }

    #[test]
    fn luminance_mid_gray_halves_alpha() {
        // Mid-gray (128,128,128) has luminance ≈ 128. Alpha 255 in,
        // expect ~128 out.
        let mut bytes = pixel(128, 128, 128, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        // Allow ±1 for rounding.
        assert!((bytes[3] as i32 - 128).abs() <= 1, "got {}", bytes[3]);
    }

    #[test]
    fn luminance_transparent_stays_transparent() {
        // Regardless of RGB, an alpha-0 pixel must stay alpha-0
        // (so the mask's "outside rendered region" doesn't
        // accidentally become opaque).
        let mut bytes = pixel(255, 255, 255, 0).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert_eq!(bytes[3], 0);
    }

    #[test]
    fn luminance_respects_source_alpha() {
        // Half-alpha white should end up at half alpha.
        let mut bytes = pixel(255, 255, 255, 128).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert_eq!(bytes[3], 128);
    }

    #[test]
    fn luminance_bt601_red_weight() {
        // Pure red (255,0,0) → luminance = 0.299 * 255 ≈ 76.
        let mut bytes = pixel(255, 0, 0, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert!((bytes[3] as i32 - 76).abs() <= 1, "got {}", bytes[3]);
    }

    #[test]
    fn luminance_bt601_green_weight() {
        // Pure green → luminance = 0.587 * 255 ≈ 150.
        let mut bytes = pixel(0, 255, 0, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert!((bytes[3] as i32 - 150).abs() <= 1, "got {}", bytes[3]);
    }

    #[test]
    fn luminance_bt601_blue_weight() {
        // Pure blue → luminance = 0.114 * 255 ≈ 29.
        let mut bytes = pixel(0, 0, 255, 255).to_vec();
        promote_bytes_to_luminance(&mut bytes);
        assert!((bytes[3] as i32 - 29).abs() <= 1, "got {}", bytes[3]);
    }

    // ── effective_mask_transform (Track C phase 3) ────────

    fn test_transform(e: f64, f: f64) -> Transform {
        // Pure translation by (e, f) for easy identification in tests.
        Transform { a: 1.0, b: 0.0, c: 0.0, d: 1.0, e, f }
    }

    fn test_rect_with_transform(t: Option<Transform>) -> Element {
        Element::Rect(RectElem {
            x: 0.0, y: 0.0, width: 10.0, height: 10.0,
            rx: 0.0, ry: 0.0,
            fill: None, stroke: None,
            common: CommonProps {
                opacity: 1.0,
                mode: BlendMode::Normal,
                transform: t,
                locked: false,
                visibility: Visibility::Preview,
                mask: None,
                tool_origin: None,
            },
                    fill_gradient: None,
            stroke_gradient: None,
        })
    }

    fn test_mask_linked(
        linked: bool,
        unlink: Option<Transform>,
    ) -> Mask {
        Mask {
            subtree: Box::new(Element::Group(GroupElem::default())),
            clip: true,
            invert: false,
            disabled: false,
            linked,
            unlink_transform: unlink,
        }
    }

    #[test]
    fn effective_mask_transform_linked_returns_element_transform() {
        // linked=true: mask follows the element, so the renderer
        // should apply ``elem.transform()``.
        let mask = test_mask_linked(true, None);
        let elem = test_rect_with_transform(Some(test_transform(5.0, 7.0)));
        let t = effective_mask_transform(&mask, &elem)
            .expect("expected Some element transform");
        assert_eq!(t.e, 5.0);
        assert_eq!(t.f, 7.0);
    }

    #[test]
    fn effective_mask_transform_linked_none_when_element_has_no_transform() {
        // linked=true with no element transform: None — the
        // compositing path skips the ``ctx.transform`` call.
        let mask = test_mask_linked(true, None);
        let elem = test_rect_with_transform(None);
        assert!(effective_mask_transform(&mask, &elem).is_none());
    }

    #[test]
    fn effective_mask_transform_unlinked_returns_captured_unlink_transform() {
        // linked=false: mask stays frozen under the unlink-time
        // transform, regardless of the element's current transform.
        let unlink = test_transform(3.0, 4.0);
        let mask = test_mask_linked(false, Some(unlink));
        let elem = test_rect_with_transform(Some(test_transform(100.0, 100.0)));
        let t = effective_mask_transform(&mask, &elem)
            .expect("expected Some unlink transform");
        assert_eq!(t.e, 3.0);
        assert_eq!(t.f, 4.0);
    }

    #[test]
    fn effective_mask_transform_unlinked_none_when_unlink_missing() {
        // linked=false with no captured transform (edge case:
        // unlinked at identity): None. Compositing skips the
        // transform call and the mask renders in ancestor coords.
        let mask = test_mask_linked(false, None);
        let elem = test_rect_with_transform(Some(test_transform(7.0, 8.0)));
        assert!(effective_mask_transform(&mask, &elem).is_none());
    }

    #[test]
    fn css_color_alpha_just_below_one() {
        let c = Color::Rgb { r: 0.0, g: 1.0, b: 0.0, a: 0.99 };
        assert_eq!(css_color(&c), "rgba(0,255,0,0.99)");
    }
}
